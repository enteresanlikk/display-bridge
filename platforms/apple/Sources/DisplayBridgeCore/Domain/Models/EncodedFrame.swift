import CoreMedia
import Foundation

public struct EncodedFrame: Sendable {
    public let timestamp: CMTime
    public let data: Data
    public let isKeyFrame: Bool
    public let sequenceNumber: UInt64

    public init(timestamp: CMTime, data: Data, isKeyFrame: Bool, sequenceNumber: UInt64) {
        self.timestamp = timestamp
        self.data = data
        self.isKeyFrame = isKeyFrame
        self.sequenceNumber = sequenceNumber
    }
}
