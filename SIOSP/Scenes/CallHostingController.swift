import UIKit
import SwiftUI
import CallKit

class CallHostingController: UIHostingController<CallView> {
    let callUUID: UUID
    var endCallHandler: (() -> Void)?
    
    init(callUUID: UUID, callerName: String, callerNumber: String) {
        self.callUUID = callUUID
        
        let callView = CallView(
            callUUID: callUUID,
            callerName: callerName,
            callerNumber: callerNumber,
            callStartTime: Date(),
            onEnd: {
                // This will be set after init
            }
        )
        
        super.init(rootView: callView)
        
        // Set the end call handler after initialization
        rootView = CallView(
            callUUID: callUUID,
            callerName: callerName,
            callerNumber: callerNumber,
            callStartTime: Date(),
            onEnd: { [weak self] in
                self?.endCallHandler?()
                self?.dismiss(animated: true)
            }
        )
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configure the view controller
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true // Prevents dismissal by swipe
    }
}

// MARK: - CallKit Integration Extension
extension CallHostingController {
    static func presentCallViewController(from viewController: UIViewController, callUUID: UUID, callerName: String, callerNumber: String, completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            let callVC = CallHostingController(
                callUUID: callUUID,
                callerName: callerName,
                callerNumber: callerNumber
            )
            
            callVC.endCallHandler = completion
            
            viewController.present(callVC, animated: true)
        }
    }
} 