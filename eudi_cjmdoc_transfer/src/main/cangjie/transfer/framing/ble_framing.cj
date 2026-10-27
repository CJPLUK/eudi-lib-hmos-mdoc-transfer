/*
 * ISO 18013-5 §8 BLE framing — chunk/reassemble state machine.
 *
 * Source ref:
 *   Sources/MdocDataTransfer18013/MdocHelpers.swift
 *   functions: prepareDataBlocksToSend / countNumBlocks / createBlockCommand
 *
 * Protocol overview (§8.3.3.2):
 *   - Each block is prefixed with a single status byte:
 *       START_DATA (0x01): more blocks follow
 *       END_DATA   (0x00): this is the last block
 *   - The remaining bytes after the prefix are the raw payload chunk.
 *   - On reassembly, the prefix byte is stripped from each block and the
 *     payloads are concatenated in order.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing

import std.collection.*

/// ISO 18013-5 §8 BLE data-frame chunking and reassembly.
///
/// All methods are pure functions — no mutable state, no I/O.
/// Thread-safety is guaranteed by the absence of shared mutable state.
public class BleTransferFraming {

    // -----------------------------------------------------------------------
    // Chunking (prepareDataBlocksToSend)
    // -----------------------------------------------------------------------

    /// Splits `msg` into BLE blocks of at most `maxBlockSize` bytes each.
    ///
    /// Every block is prefixed with a single status byte:
    ///   - START_DATA (0x01) for all blocks except the last
    ///   - END_DATA   (0x00) for the last block
    ///
    /// This mirrors Swift `MdocHelpers.prepareDataBlocksToSend(_:blockSize:)`.
    ///
    /// - Parameters:
    ///   - msg: the raw payload bytes to send
    ///   - maxBlockSize: maximum number of payload bytes per block (excluding the 1-byte header)
    /// - Returns: ordered array of framed blocks, each ready to write to Client2Server
    public static func prepareDataBlocksToSend(msg: Array<UInt8>, maxBlockSize: Int64): Array<Array<UInt8>> {
        if (msg.size == 0 || maxBlockSize <= 0) {
            return Array<Array<UInt8>>()
        }
        let numBlocks = BleTransferFraming.countNumBlocks(msg.size, maxBlockSize)
        var result = ArrayList<Array<UInt8>>()
        var i: Int64 = 0
        while (i < numBlocks) {
            let (chunk, isLast) = BleTransferFraming.createBlockCommand(msg, i, maxBlockSize)
            // prefix byte: END_DATA(0x00) if last, START_DATA(0x01) otherwise
            let prefixByte: UInt8 = if (isLast) { BleTransferModeConst.END_DATA } else { BleTransferModeConst.START_DATA }
            let block = Array<UInt8>(1 + chunk.size, {_ => 0u8})
            block[0] = prefixByte
            var j: Int64 = 0
            while (j < chunk.size) {
                block[1 + j] = chunk[j]
                j++
            }
            result.add(block)
            i++
        }
        return result.toArray()
    }

    // -----------------------------------------------------------------------
    // Block-count helper (countNumBlocks)
    // -----------------------------------------------------------------------

    /// Returns the number of blocks required to transmit `dataLength` bytes
    /// with a maximum payload of `maxBlockSize` bytes per block.
    ///
    /// Mirrors Swift `MdocHelpers.countNumBlocks(dataLength:maxBlockSize:)`.
    public static func countNumBlocks(dataLength: Int64, maxBlockSize: Int64): Int64 {
        if (maxBlockSize <= 0 || dataLength <= 0) {
            return 0
        }
        if (dataLength <= maxBlockSize) {
            return 1
        }
        var numBlocks = dataLength / maxBlockSize
        if (numBlocks * maxBlockSize < dataLength) {
            numBlocks = numBlocks + 1
        }
        return numBlocks
    }

    // -----------------------------------------------------------------------
    // Single-block extractor (createBlockCommand)
    // -----------------------------------------------------------------------

    /// Extracts block `blockId` from `data` with a maximum payload of `maxBlockSize`.
    ///
    /// Returns (chunk, isLastBlock) where chunk is the raw payload bytes
    /// (without any status-byte prefix) and isLastBlock is true when this
    /// is the final block.
    ///
    /// Mirrors Swift `MdocHelpers.createBlockCommand(data:blockId:maxBlockSize:)`.
    public static func createBlockCommand(data: Array<UInt8>, blockId: Int64, maxBlockSize: Int64): (Array<UInt8>, Bool) {
        if (data.size == 0 || maxBlockSize <= 0 || blockId < 0) {
            return (Array<UInt8>(), true)
        }
        let start = blockId * maxBlockSize
        if (start >= data.size) {
            return (Array<UInt8>(), true)
        }
        var end = (blockId + 1) * maxBlockSize
        var isLastBlock = false
        if (end >= data.size) {
            end = data.size
            isLastBlock = true
        }
        // Array slice: arr[start..end] returns a view sharing the backing store (per KB result)
        let chunk = data[start..end]
        return (chunk, isLastBlock)
    }

    // -----------------------------------------------------------------------
    // Reassembly (reassemble)
    // -----------------------------------------------------------------------

    /// Reassembles an ordered sequence of framed BLE blocks back to the original payload.
    ///
    /// Each block must begin with a status byte (START_DATA=0x01 or END_DATA=0x00).
    /// The status byte is stripped; the remaining bytes are concatenated in order.
    ///
    /// Safety guarantees:
    ///   - Empty `blocks` input → returns empty array (no panic)
    ///   - Block shorter than 2 bytes → skipped (truncation defence)
    ///   - Blocks after an END_DATA block are ignored (graceful truncation)
    ///
    /// The last block in the sequence should carry END_DATA (0x00).  If the
    /// final block carries START_DATA (indicating a truncated stream), the
    /// function still returns whatever payload was collected.
    ///
    /// - Parameter blocks: ordered framed blocks as received from the BLE characteristic
    /// - Returns: the reassembled original payload bytes
    public static func reassemble(blocks: Array<Array<UInt8>>): Array<UInt8> {
        if (blocks.size == 0) {
            return Array<UInt8>()
        }
        var totalSize: Int64 = 0
        var endSeen = false
        var validCount: Int64 = 0
        var idx: Int64 = 0
        while (idx < blocks.size && !endSeen) {
            let blk = blocks[idx]
            if (blk.size < 2) {
                // truncated block — skip header-only or empty block
                idx++
                continue
            }
            let prefix = blk[0]
            totalSize = totalSize + (blk.size - 1)
            validCount = validCount + 1
            if (prefix == BleTransferModeConst.END_DATA) {
                endSeen = true
            }
            idx++
        }
        if (totalSize == 0) {
            return Array<UInt8>()
        }
        let result = Array<UInt8>(totalSize, {_ => 0u8})
        var writePos: Int64 = 0
        var processed: Int64 = 0
        var done = false
        var bi: Int64 = 0
        while (bi < blocks.size && !done) {
            let blk = blocks[bi]
            if (blk.size < 2) {
                bi++
                continue
            }
            let prefix = blk[0]
            // copy payload bytes (everything after byte 0)
            var pi: Int64 = 1
            while (pi < blk.size) {
                result[writePos] = blk[pi]
                writePos++
                pi++
            }
            processed++
            if (prefix == BleTransferModeConst.END_DATA) {
                done = true
            }
            bi++
        }
        // trim result to actually written bytes
        if (writePos == totalSize) {
            return result
        }
        return result[0..writePos]
    }
}
