import CoreMedia
import Foundation
import VideoToolbox

/// Reports which codecs this Mac can encode/decode in hardware (used by preflight).
public enum VideoCapabilities {
    public static func hardwareDecode(_ codec: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codec)
    }

    public static func hardwareEncode(_ codec: CMVideoCodecType) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { e in
            let type = (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            let hw = (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            return type == codec && hw
        }
    }

    /// One JSON line, e.g. {"h264_encode_hw":true,...}
    public static func json() -> String {
        let items: [(String, Bool)] = [
            ("h264_encode_hw", hardwareEncode(kCMVideoCodecType_H264)),
            ("hevc_encode_hw", hardwareEncode(kCMVideoCodecType_HEVC)),
            ("h264_decode_hw", hardwareDecode(kCMVideoCodecType_H264)),
            ("hevc_decode_hw", hardwareDecode(kCMVideoCodecType_HEVC)),
        ]
        return "{" + items.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}
