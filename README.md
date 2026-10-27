# eudi_lib_mdoc_transfer

EU Digital Identity Wallet 的 **ISO/IEC 18013-5 §8 BLE 近场数据传输层**(仓颉 / HarmonyOS),移植自欧盟委员会官方参考实现 [eudi-lib-ios-iso18013-data-transfer](https://github.com/eu-digital-identity-wallet/eudi-lib-ios-iso18013-data-transfer)。

> 仅 BLE(上游 Swift 库的实际传输子目录只有 BLETransfer/,无 NFC 传输)。iOS CoreBluetooth(CBPeripheralManager/CBCentralManager)→ HarmonyOS ConnectivityKit GATT。

## 功能(4 子域)

| 子包 | 能力 | 实现策略 |
|---|---|---|
| **framing** | ISO 18013-5 §8 BLE 分片/重组状态机(START/END_DATA 前缀,`BleTransferFraming`)+ GATT 服务/特征 UUID(`ServiceCharacteristics`:State/Client2Server/Server2Client)+ 传输枚举与值类型(`BleTransferMode`/`TransferStatus`/`ErrorCode`/`RequestItem`/`UserRequestInfo`/`InitializeTransferData`) | reimplement(纯逻辑) |
| **orchestration** | 传输编排:`MdocHelpers.getSessionDataToSend`(DeviceResponse→SessionEncryption 加密→SessionData)/ `decodeRequestAndInformUser`(SessionEstablishment/DeviceRequest→RequestItem 列表)/ `getDeviceResponseToSend`(裁剪 IssuerSigned→DeviceResponse + ReaderValidation reader 证书链) | reimplement,消费上游 |
| **ble** | ConnectivityKit BLE 收发:`MdocGattServer`(holder,createGattServer/addService 三特征/startAdvertising + CharacteristicWrite 回调驱动 §8 状态机/sendResponse notify)、`MdocGattClient`(reader,startBleScanning/connect/write/subscribe)、`MdocBleTransport`(传输契约)、`MdocOfflineDelegate`(回调) | wrap_platform(ConnectivityKit) |

> **解耦设计**:§8 状态机/分片重组(`processWrittenBytes`/`processReceivedNotify`/`notifyBlocks`/`writeNextBlock`)是与 BLE 硬件回调解耦的纯逻辑方法,可被进程内 GattServer↔GattClient loopback 直接驱动(支撑单机 E2E)。

## 仓库结构(团队统一 cbor 形态)

```
eudi_lib_mdoc_transfer/
├── eudi_cjmdoc_transfer/          ← HAR 模块(pkg ohos_app_cangjie_eudi_cjmdoc_transfer)
│   ├── src/main/cangjie/index.cj  ← runMdocTransferDemo()(framing 往返 + ble loopback 自检)
│   └── src/main/cangjie/transfer/ ← framing / orchestration / ble
├── entry/                         ← 测试面板 HAP(57 个设备 E2E + "Run mDoc-Transfer Demo")
│   └── libs/{stdx, arm64-v8a}/    ← stdx 1.1.3.1 + OpenSSL/libsecurec 运行时件
└── third_party/                   ← (gitignored)上游锁定 clone,见下
```

## 上游依赖(首次构建前 — 扁平 third_party,含二级传递)

本库依赖 mdoc-security / mdoc-data-model,**且二者又依赖 cbor + core-crypto + x509**(二级传递)。解法:third_party **平铺全闭包**,并改写 mdoc-security / mdoc-data-model clone 的相对路径上跳一层(详见团队 lib-packaging-spec §9):

```bash
cd third_party
git clone https://github.com/CJPLUK/eudi-lib-hmos-mdoc-security  && (cd eudi_lib_mdoc_security  && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-mdoc-data-model && (cd eudi_lib_mdoc_data_model && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-core-crypto           && (cd eudi_lib_core_crypto && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-x509            && (cd eudi_lib_x509 && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-cbor            && (cd eudi_lib_cbor && git checkout v0.1.0)
# mdoc-security / mdoc-data-model 的 cjpm.toml 相对路径上跳到扁平层:
sed -i '' 's|\.\./third_party/|../../|g' eudi_lib_mdoc_security/eudi_cjmdoc_security/cjpm.toml
sed -i '' 's|\.\./third_party/|../../|g' eudi_lib_mdoc_data_model/eudi_cjmdoc_data_model/cjpm.toml
```

> **stdx 版本要求 1.1.3.1**(110 文件,含 `stdx.crypto.common`)。上游 x509/mdoc-security 的 `import stdx.crypto.common.DerBlob` 需此版本;1.1.0-beta(85 文件,DerBlob 在 stdx.crypto.x509)会导致编译失败。

## 下游消费(cjpm path 依赖)

```toml
[dependencies]
  [dependencies.ohos_app_cangjie_eudi_cjmdoc_transfer]
    path = "../third_party/eudi_lib_mdoc_transfer/eudi_cjmdoc_transfer"
```

```cangjie
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.*
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration.*
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.*
```

## 构建与验证

构建命令、环境变量、运行时件要求同团队 lib-packaging-spec,参照 [eudi_lib_mdoc_security](https://github.com/CJPLUK/eudi-lib-hmos-mdoc-security) README 的"构建"一节。

- **57 个设备端 E2E**(`entry/.../unittest_engine.cj`,OpenHarmonyTestRunner,真机 127.0.0.1:5555):framing 分片/重组 17 + 常量 12 + 值类型 10 + GattServer 状态机 8 + GattClient 重组 5 + **GattServer↔GattClient loopback 2** + demo 3
- 测试面板:app 内点 **Run mDoc-Transfer Demo** → framing 往返 + BLE loopback 一轮请求-响应自检结果串

> **E2E 范围**:单机逻辑层 + 进程内 loopback。真实双机 BLE 传输(holder 广播 ↔ reader 扫描连接)需第二台设备,留作手动冒烟。

## License

[Apache License 2.0](LICENSE)。本项目为 eudi-lib-ios-iso18013-data-transfer(© European Commission)的衍生移植,归属与捆绑件声明见 [NOTICE](NOTICE)。
