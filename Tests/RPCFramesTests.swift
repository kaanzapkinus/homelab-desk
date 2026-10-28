import Foundation

@main struct RPCFramesTests {
    static func main() throws {
        testHostToolRegistry()
        testFrameDecoderChunking()
        testFrameDecoderRejections()
        print("PASS: RPCFramesTests passed all checks")
    }


    static func testHostToolRegistry() {
        guard !RPCHostToolRegistry.isAllowed("execute_approved_recovery"),
              !RPCHostToolRegistry.isAllowed("bash"),
              !RPCHostToolRegistry.isAllowed("unknown_tool") else {
            fatalError("Model tools must not acquire mutation or shell authority")
        }
    }


    static func testFrameDecoderChunking() {
        let decoder = RPCFrameDecoder()

        // Create a large logical payload >= 1 MiB to satisfy byteLength >= maxRPCFrameBytes
        let innerText = String(repeating: "A", count: 1024 * 1024 + 100)
        let logicalObject: [String: Any] = [
            "type": "response",
            "id": "c_large",
            "success": true,
            "data": ["payload": innerText]
        ]
        guard let logicalData = try? JSONSerialization.data(withJSONObject: logicalObject, options: []) else {
            fatalError("Failed to serialize logical payload")
        }

        let totalLength = logicalData.count
        let chunkSize = 200 * 1024
        var chunks: [Data] = []
        var offset = 0
        while offset < totalLength {
            let end = min(offset + chunkSize, totalLength)
            chunks.append(logicalData.subdata(in: offset..<end))
            offset = end
        }

        let count = chunks.count
        guard count >= 2 else {
            fatalError("Expected at least 2 chunks for test")
        }

        for (idx, chunk) in chunks.enumerated() {
            let record: [String: Any] = [
                "type": "rpc_chunk",
                "chunkId": "test_chunk_1",
                "index": idx,
                "count": count,
                "byteLength": totalLength,
                "data": chunk.base64EncodedString()
            ]

            do {
                let result = try decoder.push(record: record)
                if idx < count - 1 {
                    guard result == nil else {
                        fatalError("Intermediate chunk must return nil")
                    }
                } else {
                    guard let finalFrame = result else {
                        fatalError("Final chunk must return reassembled frame")
                    }
                    guard (finalFrame["type"] as? String) == "response",
                          (finalFrame["id"] as? String) == "c_large",
                          let data = finalFrame["data"] as? [String: Any],
                          data["payload"] as? String == innerText else {
                        fatalError("Reassembly lost or corrupted the logical payload")
                    }
                }
            } catch {
                fatalError("Chunk push failed at index \(idx): \(error)")
            }
        }
    }

    static func testFrameDecoderRejections() {
        let decoder = RPCFrameDecoder()

        // Interrupted sequence: start a chunk sequence then send a normal frame
        let dummyChunk: [String: Any] = [
            "type": "rpc_chunk",
            "chunkId": "int_1",
            "index": 0,
            "count": 3,
            "byteLength": 1024 * 1024 + 50,
            "data": Data(count: 100).base64EncodedString()
        ]
        _ = try? decoder.push(record: dummyChunk)

        let normalFrame: [String: Any] = ["type": "abort"]
        do {
            _ = try decoder.push(record: normalFrame)
            fatalError("Interrupted chunk sequence should throw chunkInterrupted")
        } catch RPCError.chunkInterrupted {
            // Expected
        } catch {
            fatalError("Unexpected error type: \(error)")
        }

        decoder.reset()

        // Sequence mismatch: non-zero starting index
        let wrongIndexChunk: [String: Any] = [
            "type": "rpc_chunk",
            "chunkId": "wrong_1",
            "index": 1,
            "count": 2,
            "byteLength": 1024 * 1024 + 10,
            "data": Data(count: 100).base64EncodedString()
        ]
        do {
            _ = try decoder.push(record: wrongIndexChunk)
            fatalError("Non-zero start chunk must throw chunkSequenceMismatch")
        } catch RPCError.chunkSequenceMismatch {
            // Expected
        } catch {
            fatalError("Unexpected error type: \(error)")
        }
    }
}
