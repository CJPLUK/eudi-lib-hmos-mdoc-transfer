package ohos_app_cangjie_entry

import kit.ArkUI.LengthProp
import kit.ArkUI.Column
import kit.ArkUI.Row
import kit.ArkUI.Text
import kit.ArkUI.Button
import kit.ArkUI.CustomView
import kit.ArkUI.CJEntry
import kit.ArkUI.loadNativeView
import kit.ArkUI.FontWeight
import kit.ArkUI.SubscriberManager
import kit.ArkUI.ObservedProperty
import kit.ArkUI.LocalStorage
import ohos.arkui.state_macro_manage.Entry
import ohos.arkui.state_macro_manage.Component
import ohos.arkui.state_macro_manage.State
import ohos_app_cangjie_eudi_cjmdoc_transfer.runMdocTransferDemo

@Entry
@Component
class EntryView {
    @State
    var resultText: String = "点击按钮运行 mDoc-Transfer Demo"

    func build() {
        Row {
            Column {
                Text("EUDI mDoc-Transfer (Cangjie HAR)")
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                Button("Run mDoc-Transfer Demo")
                    .onClick({
                        evt => this.resultText = runMdocTransferDemo()
                    })
                Text(this.resultText)
                    .fontSize(14)
            }.width(100.percent)
        }.height(100.percent)
    }
}
