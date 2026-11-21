import SwiftUI

struct ProfileCompatibility: View {
    let profile: Profile

    var body: some View {
        List {
            if profile.nodes.isEmpty {
                Text("该配置没有本地节点，节点由 proxy-providers 在连接时加载。")
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.nodes) { node in
                Section(node.name) {
                    LabeledContent("远端", value: node.endpoint)
                    ForEach(node.compatibilityNotes, id: \.self) { note in
                        Text(note)
                    }
                }
            }
        }
        .navigationTitle("兼容提示")
    }
}

#if DEBUG
#Preview("兼容提示") {
    NavigationStack {
        ProfileCompatibility(profile: PreviewSamples.subscriptionProfile)
    }
}
#endif
