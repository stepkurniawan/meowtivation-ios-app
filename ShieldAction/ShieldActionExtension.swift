import ManagedSettings

final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for _: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void)
    {
        completionHandler(ShieldActionResponseFactory.response(for: action))
    }

    override func handle(action: ShieldAction, for _: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void)
    {
        completionHandler(ShieldActionResponseFactory.response(for: action))
    }

    override func handle(action: ShieldAction, for _: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void)
    {
        completionHandler(ShieldActionResponseFactory.response(for: action))
    }
}
