import Foundation
import CoreMedia

struct VideoPacket {
    let sequence: UInt32
    let sps: Data
    let pps: Data
    let bytes: Data

    init(sample: CMSampleBuffer, sequence: UInt32) throws {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            throw DisplayError("El codificador no entregó video H.264.")
        }
        func parameter(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            var nalLength: Int32 = 0
            try requireSuccess(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLength), "Leer parámetros H.264")
            guard let pointer, size > 0, size <= 4096, nalLength == 4 else { throw DisplayError("Formato H.264 no admitido.") }
            return Data(bytes: pointer, count: size)
        }
        self.sequence = sequence
        sps = try parameter(0); pps = try parameter(1)
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0, byteCount <= PacketChannel.maximumPacket else { throw DisplayError("Fotograma fuera de rango.") }
        var copy = Data(count: byteCount)
        let status = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
        try requireSuccess(status, "Copiar video")
        bytes = copy
    }
    init(data: Data) throws {
        guard data.count >= 17, data.first == 3 else { throw DisplayError("Paquete de video inválido.") }
        sequence = try data.uint32(at: 1)
        let spsSize = Int(try data.uint32(at: 5)), ppsSize = Int(try data.uint32(at: 9)), size = Int(try data.uint32(at: 13))
        guard (1...4096).contains(spsSize), (1...4096).contains(ppsSize), size > 0,
              17 + spsSize + ppsSize + size == data.count, data.count <= PacketChannel.maximumPacket else {
            throw DisplayError("Tamaños H.264 inválidos.")
        }
        sps = data.subdata(in: 17..<(17 + spsSize))
        pps = data.subdata(in: (17 + spsSize)..<(17 + spsSize + ppsSize))
        bytes = data.suffix(size)
        var offset = 0
        while offset < bytes.count {
            let length = Int(try bytes.uint32(at: offset))
            guard length > 0, offset + 4 + length <= bytes.count else { throw DisplayError("Unidad H.264 incompleta.") }
            offset += 4 + length
        }
    }
    func serialized() throws -> Data {
        guard 17 + sps.count + pps.count + bytes.count <= PacketChannel.maximumPacket else { throw DisplayError("El fotograma excede el límite de red.") }
        var data = Data([3]); data.put32(sequence)
        data.put32(UInt32(sps.count)); data.put32(UInt32(pps.count)); data.put32(UInt32(bytes.count))
        data.append(sps); data.append(pps); data.append(bytes)
        return data
    }
    func formatDescription() throws -> CMVideoFormatDescription {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        try requireSuccess(status, "Crear formato H.264")
        guard let format else { throw DisplayError("Formato de video vacío.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 3840, dimensions.height <= 2160 else {
            throw DisplayError("Resolución recibida fuera de rango.")
        }
        return format
    }
    func sampleBuffer(format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try requireSuccess(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block), "Reservar video")
        guard let block else { throw DisplayError("No se pudo reservar memoria de video.") }
        try bytes.withUnsafeBytes {
            try requireSuccess(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count), "Recibir video")
        }
        var sample: CMSampleBuffer?, size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 60), decodeTimeStamp: .invalid)
        try requireSuccess(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), "Preparar video")
        guard let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw DisplayError("No se pudo preparar el fotograma.")
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }
}
