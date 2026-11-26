import SwiftUI

/// System share button for a profile: shares the subscription URL when the
/// profile comes from a URL, or exports its YAML configuration file otherwise.
struct ProfileShareLink<Label: View>: View {
    let profile: Profile
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let url = profile.sourceURL {
            ShareLink(
                item: url,
                preview: SharePreview(profile.name, icon: Image(systemName: "link"))
            ) {
                label()
            }
        } else {
            ShareLink(
                item: ProfileYAMLTransferable(profile: profile),
                preview: SharePreview(
                    ProfileShare.fileName(for: profile.name),
                    icon: Image(systemName: "doc.text")
                )
            ) {
                label()
            }
        }
    }
}

#if DEBUG
#Preview("分享配置") {
    List {
        ProfileShareLink(profile: PreviewSamples.subscriptionProfile) {
            Label(
                ProfileShare.actionTitle(for: PreviewSamples.subscriptionProfile),
                systemImage: "square.and.arrow.up"
            )
        }
        ProfileShareLink(profile: PreviewSamples.localProfile) {
            Label(
                ProfileShare.actionTitle(for: PreviewSamples.localProfile),
                systemImage: "square.and.arrow.up"
            )
        }
    }
}
#endif
