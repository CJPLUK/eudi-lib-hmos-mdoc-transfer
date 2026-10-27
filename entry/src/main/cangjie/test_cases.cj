package ohos_app_cangjie_entry

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.Path
import std.fs.Directory
import std.fs.File
import kit.PerformanceAnalysisKit.Hilog
import kit.TestKit.AbilityDelegatorRegistry
import kit.TestKit.TestRunner
import kit.AbilityKit.BundleManager
import kit.AbilityKit.BundleFlag
import kit.AbilityKit.Want

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferFraming
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferModeConst
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ServiceCharacteristics
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.RequestItem
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.UserRequestInfo
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.InitializeTransferData
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.InitializeTransferInfo
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattServer
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattClient
import ohos_app_cangjie_eudi_cjmdoc_transfer.runMdocTransferDemo

// ============================================================================
// Test class 1: BleTransferFraming — framing / chunking / reassembly
// ============================================================================

@Test
class FramingE2EUT {

    @TestCase
    func countNumBlocks_exactFit(): Unit {
        let n = BleTransferFraming.countNumBlocks(10, 10)
        @Expect(n, 1)
    }

    @TestCase
    func countNumBlocks_remainder(): Unit {
        let n = BleTransferFraming.countNumBlocks(11, 10)
        @Expect(n, 2)
    }

    @TestCase
    func countNumBlocks_singleByte(): Unit {
        let n = BleTransferFraming.countNumBlocks(1, 511)
        @Expect(n, 1)
    }

    @TestCase
    func countNumBlocks_largePayload(): Unit {
        let n = BleTransferFraming.countNumBlocks(1024, 511)
        @Expect(n, 3)
    }

    @TestCase
    func countNumBlocks_zeroData(): Unit {
        let n = BleTransferFraming.countNumBlocks(0, 511)
        @Expect(n, 0)
    }

    @TestCase
    func countNumBlocks_zeroBlockSize(): Unit {
        let n = BleTransferFraming.countNumBlocks(100, 0)
        @Expect(n, 0)
    }

    @TestCase
    func prepareDataBlocks_singleBlock_hasEndDataPrefix(): Unit {
        let payload: Array<UInt8> = [1u8, 2u8, 3u8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 10)
        @Expect(blocks.size, 1)
        @Expect(blocks[0][0], BleTransferModeConst.END_DATA)
    }

    @TestCase
    func prepareDataBlocks_multiBlock_prefixesCorrect(): Unit {
        let payload: Array<UInt8> = [10u8, 20u8, 30u8, 40u8, 50u8, 60u8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 2)
        @Expect(blocks.size, 3)
        @Expect(blocks[0][0], BleTransferModeConst.START_DATA)
        @Expect(blocks[1][0], BleTransferModeConst.START_DATA)
        @Expect(blocks[2][0], BleTransferModeConst.END_DATA)
    }

    @TestCase
    func prepareDataBlocks_payloadPreserved(): Unit {
        let payload: Array<UInt8> = [0xAAu8, 0xBBu8, 0xCCu8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 2)
        @Expect(blocks[0][1], 0xAAu8)
        @Expect(blocks[0][2], 0xBBu8)
        @Expect(blocks[1][1], 0xCCu8)
    }

    @TestCase
    func prepareDataBlocks_emptyPayload(): Unit {
        let payload: Array<UInt8> = Array<UInt8>()
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 511)
        @Expect(blocks.size, 0)
    }

    @TestCase
    func reassemble_emptyBlocks(): Unit {
        let blocks = Array<Array<UInt8>>()
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, 0)
    }

    @TestCase
    func reassemble_singleEndDataBlock(): Unit {
        let blk: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x42u8]
        let blocks: Array<Array<UInt8>> = [blk]
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, 1)
        @Expect(result[0], 0x42u8)
    }

    @TestCase
    func reassemble_roundTrip_small(): Unit {
        let payload: Array<UInt8> = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 10u8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 4)
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, payload.size)
        var i: Int64 = 0
        while (i < payload.size) {
            @Expect(result[i], payload[i])
            i++
        }
    }

    @TestCase
    func reassemble_roundTrip_1024bytes(): Unit {
        let payloadSize: Int64 = 1024
        let payload = Array<UInt8>(payloadSize, {i => UInt8(i % 256)})
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 511)
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, payloadSize)
        var i: Int64 = 0
        while (i < payloadSize) {
            @Expect(result[i], payload[i])
            i++
        }
    }

    @TestCase
    func reassemble_truncatedBlock_nocrash(): Unit {
        let shortBlk: Array<UInt8> = [BleTransferModeConst.START_DATA]
        let goodBlk: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x55u8]
        let blocks: Array<Array<UInt8>> = [shortBlk, goodBlk]
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, 1)
        @Expect(result[0], 0x55u8)
    }

    @TestCase
    func reassemble_onlyEndDataBlock_preservesPayload(): Unit {
        let blk: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x01u8, 0x02u8, 0x03u8]
        let blocks: Array<Array<UInt8>> = [blk]
        let result = BleTransferFraming.reassemble(blocks)
        @Expect(result.size, 3)
        @Expect(result[0], 0x01u8)
        @Expect(result[1], 0x02u8)
        @Expect(result[2], 0x03u8)
    }

    @TestCase
    func countNumBlocks_matchesPrepareResult(): Unit {
        let payload = Array<UInt8>(200, {i => UInt8(i % 256)})
        let maxBlockSize: Int64 = 64
        let expectedCount = BleTransferFraming.countNumBlocks(200, maxBlockSize)
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, maxBlockSize)
        @Expect(blocks.size, expectedCount)
    }
}

// ============================================================================
// Test class 2: ServiceCharacteristics & BleTransferModeConst — UUID / byte constants
// ============================================================================

@Test
class ConstantsE2EUT {

    @TestCase
    func stateUuid_value(): Unit {
        @Expect(ServiceCharacteristics.STATE_UUID, "00000001-A123-48CE-896B-4C76973373E6")
    }

    @TestCase
    func client2ServerUuid_value(): Unit {
        @Expect(ServiceCharacteristics.CLIENT_2_SERVER_UUID, "00000002-A123-48CE-896B-4C76973373E6")
    }

    @TestCase
    func server2ClientUuid_value(): Unit {
        @Expect(ServiceCharacteristics.SERVER_2_CLIENT_UUID, "00000003-A123-48CE-896B-4C76973373E6")
    }

    @TestCase
    func uuids_areDistinct(): Unit {
        let allDifferent =
            ServiceCharacteristics.STATE_UUID != ServiceCharacteristics.CLIENT_2_SERVER_UUID &&
            ServiceCharacteristics.CLIENT_2_SERVER_UUID != ServiceCharacteristics.SERVER_2_CLIENT_UUID &&
            ServiceCharacteristics.STATE_UUID != ServiceCharacteristics.SERVER_2_CLIENT_UUID
        @Expect(allDifferent, true)
    }

    @TestCase
    func descriptionFor_stateUuid(): Unit {
        let desc = ServiceCharacteristics.descriptionFor(ServiceCharacteristics.STATE_UUID)
        @Expect(desc, "State")
    }

    @TestCase
    func descriptionFor_client2Server(): Unit {
        let desc = ServiceCharacteristics.descriptionFor(ServiceCharacteristics.CLIENT_2_SERVER_UUID)
        @Expect(desc, "Client to Server")
    }

    @TestCase
    func descriptionFor_server2Client(): Unit {
        let desc = ServiceCharacteristics.descriptionFor(ServiceCharacteristics.SERVER_2_CLIENT_UUID)
        @Expect(desc, "Server to Client")
    }

    @TestCase
    func descriptionFor_unknown(): Unit {
        let desc = ServiceCharacteristics.descriptionFor("00000099-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        @Expect(desc, "Unknown")
    }

    @TestCase
    func bleTransferModeConst_startRequest(): Unit {
        @Expect(BleTransferModeConst.START_REQUEST, 0x01u8)
    }

    @TestCase
    func bleTransferModeConst_endRequest(): Unit {
        @Expect(BleTransferModeConst.END_REQUEST, 0x02u8)
    }

    @TestCase
    func bleTransferModeConst_startData(): Unit {
        @Expect(BleTransferModeConst.START_DATA, 0x01u8)
    }

    @TestCase
    func bleTransferModeConst_endData(): Unit {
        @Expect(BleTransferModeConst.END_DATA, 0x00u8)
    }
}

// ============================================================================
// Test class 3: Value types (RequestItem, UserRequestInfo, InitializeTransferData)
// ============================================================================

@Test
class ValueTypesE2EUT {

    @TestCase
    func requestItem_construction(): Unit {
        let path: Array<String> = ["family_name"]
        let item = RequestItem(path, Some(true), Some(false))
        @Expect(item.elementPath.size, 1)
        @Expect(item.elementPath[0], "family_name")
        @Expect(item.intentToRetain, Some(true))
        @Expect(item.isOptional, Some(false))
    }

    @TestCase
    func requestItem_fromIdentifier_singleSegment(): Unit {
        let item = RequestItem.fromIdentifier("family_name", None, None)
        @Expect(item.elementPath.size, 1)
        @Expect(item.elementPath[0], "family_name")
    }

    @TestCase
    func requestItem_fromIdentifier_multiSegment(): Unit {
        let item = RequestItem.fromIdentifier("driving_privileges.0", None, None)
        @Expect(item.elementPath.size, 2)
        @Expect(item.elementPath[0], "driving_privileges")
        @Expect(item.elementPath[1], "0")
    }

    @TestCase
    func requestItem_elementIdentifier_singleSegment(): Unit {
        let item = RequestItem.fromIdentifier("family_name", None, None)
        @Expect(item.elementIdentifier(), "family_name")
    }

    @TestCase
    func requestItem_elementIdentifier_multiSegment(): Unit {
        let item = RequestItem.fromIdentifier("driving_privileges.0", None, None)
        @Expect(item.elementIdentifier(), "driving_privileges.0")
    }

    @TestCase
    func requestItem_rootIdentifier(): Unit {
        let item = RequestItem.fromIdentifier("driving_privileges.0", None, None)
        @Expect(item.rootIdentifier(), "driving_privileges")
    }

    @TestCase
    func requestItem_rootIdentifier_empty(): Unit {
        let item = RequestItem(Array<String>(), None, None)
        @Expect(item.rootIdentifier(), "")
    }

    @TestCase
    func userRequestInfo_construction(): Unit {
        let reqBytes: Array<UInt8> = [0xA1u8, 0x01u8]
        let items: Array<(String, Array<RequestItem>)> = Array<(String, Array<RequestItem>)>()
        let info = UserRequestInfo(reqBytes, items)
        @Expect(info.deviceRequestBytes.size, 2)
        @Expect(info.deviceRequestBytes[0], 0xA1u8)
        @Expect(info.itemsRequested.size, 0)
        @Expect(info.readerAuthResults.size, 0)
    }

    @TestCase
    func initializeTransferData_construction(): Unit {
        let dataFormats: Array<(String, String)> = [("doc1", "cbor")]
        let documentData: Array<(String, Array<UInt8>)> = [("doc1", [0x01u8, 0x02u8])]
        let keyIndexes: Array<(String, Int64)> = [("doc1", 0)]
        let idsToTypes: Array<(String, String)> = [("doc1", "org.iso.18013.5.1.mDL")]
        let data = InitializeTransferData(dataFormats, documentData, keyIndexes, "deviceMac", idsToTypes)
        @Expect(data.deviceAuthMethod, "deviceMac")
        @Expect(data.dataFormats.size, 1)
        @Expect(data.documentData.size, 1)
        let (idsKey, idsVal) = data.idsToDocTypes[0]
        @Expect(idsKey, "doc1")
        @Expect(idsVal, "org.iso.18013.5.1.mDL")
    }

    @TestCase
    func initializeTransferInfo_construction(): Unit {
        let dataFormats: Array<(String, String)> = [("doc1", "cbor")]
        let docObjects: Array<(String, Array<UInt8>)> = [("doc1", [0x83u8])]
        let idsToTypes: Array<(String, String)> = [("doc1", "org.iso.18013.5.1.mDL")]
        let info = InitializeTransferInfo(dataFormats, docObjects, "deviceSign", idsToTypes)
        @Expect(info.deviceAuthMethod, "deviceSign")
        @Expect(info.dataFormats.size, 1)
        @Expect(info.documentObjects.size, 1)
        @Expect(info.idsToDocTypes.size, 1)
    }
}

// ============================================================================
// Test class 4: GattServer.processWrittenBytes state machine (loopback)
// ============================================================================

@Test
class GattServerStateMachineE2EUT {

    @TestCase
    func processWrittenBytes_startRequest_returnsNone(): Unit {
        let server = MdocGattServer()
        let startReq: Array<UInt8> = [BleTransferModeConst.START_REQUEST]
        let result = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, startReq)
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processWrittenBytes_endRequest_returnsNone(): Unit {
        let server = MdocGattServer()
        let endReq: Array<UInt8> = [BleTransferModeConst.END_REQUEST]
        let result = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, endReq)
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processWrittenBytes_emptyBytes_returnsNone(): Unit {
        let server = MdocGattServer()
        let result = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, Array<UInt8>())
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processWrittenBytes_singleFragmentRequest(): Unit {
        let server = MdocGattServer()
        let payload: Array<UInt8> = [0x01u8, 0x02u8, 0x03u8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 64)
        @Expect(blocks.size, 1)
        var assembled: ?Array<UInt8> = None
        var i: Int64 = 0
        while (i < blocks.size) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, blocks[i])
            match (res) {
                case Some(p) => assembled = Some(p)
                case None => ()
            }
            i++
        }
        match (assembled) {
            case None => @Expect(false, true)
            case Some(p) =>
                @Expect(p.size, 3)
                @Expect(p[0], 0x01u8)
                @Expect(p[1], 0x02u8)
                @Expect(p[2], 0x03u8)
        }
    }

    @TestCase
    func processWrittenBytes_multiFragmentRequest(): Unit {
        let server = MdocGattServer()
        let payload = Array<UInt8>(200, {i => UInt8((i + 7) % 256)})
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 64)
        var assembled: ?Array<UInt8> = None
        var i: Int64 = 0
        while (i < blocks.size) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, blocks[i])
            match (res) {
                case Some(p) => assembled = Some(p)
                case None => ()
            }
            i++
        }
        match (assembled) {
            case None => @Expect(false, true)
            case Some(p) =>
                @Expect(p.size, payload.size)
                var j: Int64 = 0
                while (j < payload.size) {
                    @Expect(p[j], payload[j])
                    j++
                }
        }
    }

    @TestCase
    func processWrittenBytes_intermediateBlocks_returnNone(): Unit {
        let server = MdocGattServer()
        let payload = Array<UInt8>(200, {i => UInt8(i % 256)})
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 64)
        var i: Int64 = 0
        while (i < blocks.size - 1) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, blocks[i])
            match (res) {
                case None => ()
                case Some(_) => @Expect(false, true)
            }
            i++
        }
        let lastRes = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, blocks[blocks.size - 1])
        match (lastRes) {
            case None => @Expect(false, true)
            case Some(_) => ()
        }
    }

    @TestCase
    func processWrittenBytes_unknownUuid_returnsNone(): Unit {
        let server = MdocGattServer()
        let bytes: Array<UInt8> = [0x01u8]
        let result = server.processWrittenBytes("00000099-FFFF-FFFF-FFFF-FFFFFFFFFFFF", bytes)
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processWrittenBytes_bufferResetAfterStartRequest(): Unit {
        let server = MdocGattServer()
        let _ = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, [BleTransferModeConst.START_REQUEST])
        let payload: Array<UInt8> = [0xAAu8, 0xBBu8]
        let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 64)
        var assembled: ?Array<UInt8> = None
        var i: Int64 = 0
        while (i < blocks.size) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, blocks[i])
            match (res) {
                case Some(p) => assembled = Some(p)
                case None => ()
            }
            i++
        }
        match (assembled) {
            case None => @Expect(false, true)
            case Some(p) =>
                @Expect(p.size, 2)
                @Expect(p[0], 0xAAu8)
                @Expect(p[1], 0xBBu8)
        }
    }
}

// ============================================================================
// Test class 5: GattClient.processReceivedNotify (loopback)
// ============================================================================

@Test
class GattClientReassemblyE2EUT {

    @TestCase
    func processReceivedNotify_wrongUuid_returnsNone(): Unit {
        let client = MdocGattClient()
        let bytes: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x01u8]
        let result = client.processReceivedNotify(ServiceCharacteristics.CLIENT_2_SERVER_UUID, bytes)
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processReceivedNotify_emptyBytes_returnsNone(): Unit {
        let client = MdocGattClient()
        let result = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, Array<UInt8>())
        match (result) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func processReceivedNotify_singleEndDataBlock(): Unit {
        let client = MdocGattClient()
        let blk: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x42u8, 0x43u8]
        let result = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, blk)
        match (result) {
            case None => @Expect(false, true)
            case Some(p) =>
                @Expect(p.size, 2)
                @Expect(p[0], 0x42u8)
                @Expect(p[1], 0x43u8)
        }
    }

    @TestCase
    func processReceivedNotify_multiFragment_roundTrip(): Unit {
        let client = MdocGattClient()
        let responsePayload = Array<UInt8>(300, {i => UInt8((i + 13) % 256)})
        let blocks = BleTransferFraming.prepareDataBlocksToSend(responsePayload, 64)
        var assembled: ?Array<UInt8> = None
        var i: Int64 = 0
        while (i < blocks.size) {
            let res = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, blocks[i])
            match (res) {
                case Some(p) => assembled = Some(p)
                case None => ()
            }
            i++
        }
        match (assembled) {
            case None => @Expect(false, true)
            case Some(p) =>
                @Expect(p.size, responsePayload.size)
                var j: Int64 = 0
                while (j < responsePayload.size) {
                    @Expect(p[j], responsePayload[j])
                    j++
                }
        }
    }

    @TestCase
    func processReceivedNotify_intermediateBlocks_returnNone(): Unit {
        let client = MdocGattClient()
        let responsePayload = Array<UInt8>(150, {i => UInt8(i % 256)})
        let blocks = BleTransferFraming.prepareDataBlocksToSend(responsePayload, 50)
        var i: Int64 = 0
        while (i < blocks.size - 1) {
            let res = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, blocks[i])
            match (res) {
                case None => ()
                case Some(_) => @Expect(false, true)
            }
            i++
        }
        let lastRes = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, blocks[blocks.size - 1])
        match (lastRes) {
            case None => @Expect(false, true)
            case Some(_) => ()
        }
    }
}

// ============================================================================
// Test class 6: Full GattServer <-> GattClient in-process loopback
// ============================================================================

@Test
class BleLoopbackE2EUT {

    @TestCase
    func fullLoopback_requestResponse_200B_300B(): Unit {
        let server = MdocGattServer()
        let client = MdocGattClient()

        let startReq: Array<UInt8> = [BleTransferModeConst.START_REQUEST]
        let startResult = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, startReq)
        match (startResult) {
            case None => ()
            case Some(_) => @Expect(false, true)
        }

        let requestPayload = Array<UInt8>(200, {i => UInt8((i + 7) % 256)})
        let requestBlocks = BleTransferFraming.prepareDataBlocksToSend(requestPayload, 64)
        var serverReassembled: ?Array<UInt8> = None
        var bi: Int64 = 0
        while (bi < requestBlocks.size) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, requestBlocks[bi])
            match (res) {
                case Some(p) => serverReassembled = Some(p)
                case None => ()
            }
            bi++
        }
        let serverPayload: Array<UInt8> = match (serverReassembled) {
            case None =>
                @Expect(false, true)
                Array<UInt8>()
            case Some(p) => p
        }
        @Expect(serverPayload.size, requestPayload.size)

        let responsePayload = Array<UInt8>(300, {i => UInt8((i + 13) % 256)})
        let responseBlocks = BleTransferFraming.prepareDataBlocksToSend(responsePayload, 64)
        var clientReassembled: ?Array<UInt8> = None
        var ri: Int64 = 0
        while (ri < responseBlocks.size) {
            let res = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, responseBlocks[ri])
            match (res) {
                case Some(p) => clientReassembled = Some(p)
                case None => ()
            }
            ri++
        }
        let clientPayload: Array<UInt8> = match (clientReassembled) {
            case None =>
                @Expect(false, true)
                Array<UInt8>()
            case Some(p) => p
        }
        @Expect(clientPayload.size, responsePayload.size)

        var ci: Int64 = 0
        while (ci < responsePayload.size) {
            @Expect(clientPayload[ci], responsePayload[ci])
            ci++
        }
    }

    @TestCase
    func fullLoopback_largePayload_1024B(): Unit {
        let server = MdocGattServer()
        let client = MdocGattClient()

        let _ = server.processWrittenBytes(ServiceCharacteristics.STATE_UUID, [BleTransferModeConst.START_REQUEST])

        let requestPayload = Array<UInt8>(1024, {i => UInt8(i % 256)})
        let requestBlocks = BleTransferFraming.prepareDataBlocksToSend(requestPayload, 511)
        var serverReassembled: ?Array<UInt8> = None
        var bi: Int64 = 0
        while (bi < requestBlocks.size) {
            let res = server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, requestBlocks[bi])
            match (res) {
                case Some(p) => serverReassembled = Some(p)
                case None => ()
            }
            bi++
        }
        match (serverReassembled) {
            case None => @Expect(false, true)
            case Some(p) => @Expect(p.size, 1024)
        }

        let responsePayload = Array<UInt8>(1024, {i => UInt8((i + 128) % 256)})
        let responseBlocks = BleTransferFraming.prepareDataBlocksToSend(responsePayload, 511)
        var clientReassembled: ?Array<UInt8> = None
        var ri: Int64 = 0
        while (ri < responseBlocks.size) {
            let res = client.processReceivedNotify(ServiceCharacteristics.SERVER_2_CLIENT_UUID, responseBlocks[ri])
            match (res) {
                case Some(p) => clientReassembled = Some(p)
                case None => ()
            }
            ri++
        }
        match (clientReassembled) {
            case None => @Expect(false, true)
            case Some(p) => @Expect(p.size, 1024)
        }
    }
}

// ============================================================================
// Test class 7: runMdocTransferDemo integration smoke test
// ============================================================================

@Test
class DemoIntegrationE2EUT {

    @TestCase
    func runMdocTransferDemo_containsPassA(): Unit {
        let result = runMdocTransferDemo()
        let hasPassA = result.contains("A) Framing round-trip: PASS")
        @Expect(hasPassA, true)
    }

    @TestCase
    func runMdocTransferDemo_containsPassB(): Unit {
        let result = runMdocTransferDemo()
        let hasPassB = result.contains("B) BLE loopback (pure methods): PASS")
        @Expect(hasPassB, true)
    }

    @TestCase
    func runMdocTransferDemo_noFail(): Unit {
        let result = runMdocTransferDemo()
        let hasFail = result.contains("FAIL")
        @Expect(hasFail, false)
    }
}

// ============================================================================
// OpenHarmonyTestRunner — working pattern from eudi_lib_mdoc_data_model
// ============================================================================



