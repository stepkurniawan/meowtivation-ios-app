import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding _: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding _: Application, in _: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding _: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding _: WebDomain, in _: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    private func configuration() -> ShieldConfiguration {
        let defaults = UserDefaults(suiteName: AppSettings.appGroup)
        let userName = defaults?.string(forKey: AppSettings.userNameKey)
        let titleColor = UIColor.label

        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(named: "ShieldArtwork"),
            title: .init(text: ShieldMessage.greeting(for: userName), color: titleColor),
            subtitle: .init(text: ShieldMessage.subtitle, color: UIColor.secondaryLabel),
            primaryButtonLabel: .init(text: ShieldMessage.primaryButtonTitle, color: .white),
            primaryButtonBackgroundColor: UIColor.systemIndigo
        )
    }
}
