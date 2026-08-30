import AudioToolbox
import Synchronization

/// The result of trying to reserve a slot in the capture ring.
///
/// A producer never waits for the publisher. When the ring is full the newest
/// slice is discarded, which keeps the callback bounded and lets the publisher
/// continue transcribing the oldest audio it has already accepted.
internal enum AudioChunkWriteResult {
    case reserved(AudioChunkRing.WriteReservation)
    case full
    case oversized
    case closed
}

/// A fixed-capacity, single-producer/single-consumer handoff for planar
/// Float32 audio.
///
/// The CoreAudio callback is the sole producer and the detached publisher is
/// the sole consumer. The producer owns `producerPosition`, the consumer owns
/// `consumerPosition`; each side reads the other side's atomic index with
/// acquire ordering and publishes its own index with release ordering. Audio
/// samples and slot metadata are therefore written before the release store
/// and read only after the matching acquire load. No lock, allocation, or
/// waiting operation is used by the producer path.
internal final class AudioChunkRing: @unchecked Sendable {
    internal struct WriteReservation {
        fileprivate let position: UInt64
        fileprivate let slotIndex: Int
        fileprivate let frameCount: Int
    }

    internal struct Chunk {
        fileprivate let position: UInt64
        fileprivate let slot: Slot

        internal var frameCount: Int { slot.frameCount }
        internal var channelCount: Int { slot.channelCount }
        internal var audioBufferList: UnsafeMutablePointer<AudioBufferList> {
            slot.audioBufferList.unsafeMutablePointer
        }
        internal var channelData: [UnsafeMutablePointer<Float>] { slot.channelData }
    }

    fileprivate final class Slot: @unchecked Sendable {
        let audioBufferList: UnsafeMutableAudioBufferListPointer
        let channelData: [UnsafeMutablePointer<Float>]
        let maxFrames: Int
        let channelCount: Int
        var frameCount: Int = 0

        init(maxFrames: Int, channelCount: Int) {
            self.maxFrames = maxFrames
            self.channelCount = channelCount

            let list = AudioBufferList.allocate(maximumBuffers: channelCount)
            list.count = channelCount
            self.audioBufferList = list

            var pointers: [UnsafeMutablePointer<Float>] = []
            pointers.reserveCapacity(channelCount)
            for channelIndex in 0..<channelCount {
                let samples = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
                pointers.append(samples)
                list[channelIndex] = AudioBuffer(
                    mNumberChannels: 1,
                    // AudioUnitRender needs the destination capacity before
                    // the first callback. The committed frame count remains
                    // separate metadata for the publisher.
                    mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.stride),
                    mData: UnsafeMutableRawPointer(samples)
                )
            }
            self.channelData = pointers
        }

        deinit {
            for samples in channelData {
                samples.deallocate()
            }
            audioBufferList.unsafeMutablePointer.deallocate()
        }
    }

    internal let capacity: Int
    internal let maxFrames: Int
    internal let channelCount: Int

    private let slots: [Slot]
    // A full ring still has to consume the HAL input pull. This sink is never
    // published and is sized once during start, so the callback can render a
    // dropped slice without allocating or overwriting a queued slot.
    private let discardSlot: Slot
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let closed = Atomic<Bool>(false)
    private let droppedNewest = Atomic<UInt64>(0)
    private let oversizedSlices = Atomic<UInt64>(0)
    private let enqueuedSlices = Atomic<UInt64>(0)

    // These are touched by one side only and are deliberately non-atomic.
    private var producerPosition: UInt64 = 0
    private var consumerPosition: UInt64 = 0

    internal init(maxFrames: Int, channelCount: Int, capacity: Int = 8) {
        precondition(maxFrames > 0, "AudioChunkRing requires a positive maxFrames")
        precondition(channelCount > 0, "AudioChunkRing requires a positive channelCount")
        precondition(capacity > 0, "AudioChunkRing requires a positive capacity")

        self.capacity = capacity
        self.maxFrames = maxFrames
        self.channelCount = channelCount
        self.slots = (0..<capacity).map { _ in
            Slot(maxFrames: maxFrames, channelCount: channelCount)
        }
        self.discardSlot = Slot(maxFrames: maxFrames, channelCount: channelCount)
    }

    internal var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    internal var droppedNewestCount: UInt64 {
        droppedNewest.load(ordering: .acquiring)
    }

    internal var oversizedSliceCount: UInt64 {
        oversizedSlices.load(ordering: .acquiring)
    }

    internal var enqueuedSliceCount: UInt64 {
        enqueuedSlices.load(ordering: .acquiring)
    }

    /// Reserves the next slot without making it visible to the consumer.
    /// The caller must either commit or abandon the reservation before asking
    /// for another slot. The CoreAudio callback uses this to render directly
    /// into the preallocated slot's AudioBufferList.
    internal func beginWrite(frames: UInt32, channelCount: UInt32) -> AudioChunkWriteResult {
        guard !closed.load(ordering: .acquiring) else { return .closed }

        guard frames > 0,
              Int(frames) <= maxFrames,
              channelCount == UInt32(self.channelCount) else {
            oversizedSlices.wrappingAdd(1, ordering: .relaxed)
            return .oversized
        }

        let read = readIndex.load(ordering: .acquiring)
        guard producerPosition &- read < UInt64(capacity) else {
            droppedNewest.wrappingAdd(1, ordering: .relaxed)
            return .full
        }

        let position = producerPosition
        return .reserved(WriteReservation(
            position: position,
            slotIndex: Int(position % UInt64(capacity)),
            frameCount: Int(frames)
        ))
    }

    /// Returns the destination list for an outstanding producer reservation.
    /// This only performs an array lookup and pointer return on the callback.
    internal func audioBufferList(for reservation: WriteReservation) -> UnsafeMutablePointer<AudioBufferList> {
        let slot = slots[reservation.slotIndex]
        prepareAudioBufferList(slot)
        return slot.audioBufferList.unsafeMutablePointer
    }

    /// Returns the fixed sink used when a producer slice is dropped because
    /// the queue is full. A caller must only request a destination that fits
    /// the preallocated capacity; an oversized slice is rejected rather than
    /// risking an out-of-bounds AudioUnitRender write.
    internal func discardBufferList(frames: UInt32,
                                    channelCount: UInt32) -> UnsafeMutablePointer<AudioBufferList>? {
        guard frames > 0,
              Int(frames) <= maxFrames,
              channelCount == UInt32(self.channelCount) else {
            return nil
        }
        prepareAudioBufferList(discardSlot)
        return discardSlot.audioBufferList.unsafeMutablePointer
    }

    /// Publishes a rendered reservation to the consumer.
    internal func commitWrite(_ reservation: WriteReservation) {
        let slot = slots[reservation.slotIndex]
        slot.frameCount = reservation.frameCount
        let byteSize = UInt32(reservation.frameCount * MemoryLayout<Float>.stride)
        for channelIndex in 0..<channelCount {
            slot.audioBufferList[channelIndex].mDataByteSize = byteSize
        }

        // Metadata and samples are visible before this release publication.
        producerPosition = reservation.position &+ 1
        writeIndex.store(producerPosition, ordering: .releasing)
        enqueuedSlices.wrappingAdd(1, ordering: .relaxed)
    }

    /// Abandons a failed render. The producer position is intentionally left
    /// unchanged so the next slice can reuse the same slot.
    internal func abandonWrite(_ reservation: WriteReservation) {
        _ = reservation
    }

    /// Test/support-only copy path. Production uses begin/commit around
    /// AudioUnitRender so no source array or copy closure is created by the
    /// realtime callback.
    @discardableResult
    internal func enqueue(planarSamples: [[Float]]) -> AudioChunkWriteResult {
        guard let firstChannel = planarSamples.first else {
            oversizedSlices.wrappingAdd(1, ordering: .relaxed)
            return .oversized
        }
        let frames = firstChannel.count
        guard frames <= Int(UInt32.max),
              planarSamples.allSatisfy({ $0.count == frames }) else {
            oversizedSlices.wrappingAdd(1, ordering: .relaxed)
            return .oversized
        }

        let reservationResult = beginWrite(
            frames: UInt32(frames),
            channelCount: UInt32(planarSamples.count)
        )
        guard case .reserved(let reservation) = reservationResult else {
            return reservationResult
        }

        let destination = slots[reservation.slotIndex].channelData
        for channelIndex in 0..<channelCount {
            planarSamples[channelIndex].withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress, frames > 0 else { return }
                destination[channelIndex].update(from: baseAddress, count: frames)
            }
        }
        commitWrite(reservation)
        return .reserved(reservation)
    }

    /// Returns the oldest published slot. The consumer must call `release`
    /// after it has copied/processed the slot, allowing the producer to reuse
    /// it.
    internal func pop() -> Chunk? {
        let write = writeIndex.load(ordering: .acquiring)
        guard consumerPosition < write else { return nil }

        let position = consumerPosition
        let slot = slots[Int(position % UInt64(capacity))]
        return Chunk(position: position, slot: slot)
    }

    internal func release(_ chunk: Chunk) {
        guard chunk.position == consumerPosition else { return }
        consumerPosition = consumerPosition &+ 1
        // Slot samples have been consumed before this release publication.
        readIndex.store(consumerPosition, ordering: .releasing)
    }

    /// Closes admission for future producer reservations. Existing published
    /// slots remain available to the consumer and are drained normally.
    internal func close() {
        closed.store(true, ordering: .releasing)
    }

    /// Releases all currently published slots from the consumer side.
    internal func drain() {
        while let chunk = pop() {
            release(chunk)
        }
    }

    private func prepareAudioBufferList(_ slot: Slot) {
        let byteSize = UInt32(maxFrames * MemoryLayout<Float>.stride)
        for channelIndex in 0..<channelCount {
            slot.audioBufferList[channelIndex].mDataByteSize = byteSize
        }
    }
}
