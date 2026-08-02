import SwiftUI

struct LoginView: View {
    let calls: AppCallService

    @State private var domain: String = UserDefaults.standard.string(forKey: "domain") ?? ""
    @State private var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    @State private var password: String = UserDefaults.standard.string(forKey: "password") ?? ""
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isLoggingIn = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Title
                        VStack {
                            Text("Majordomo Dialer")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .padding(.top, 30)
                            
                            Text("Enter the details of your SIP account")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 10)
                        }
                        
                        // Sign-in form
                        VStack(spacing: 15) {
                            // SIP server domain
                            VStack(alignment: .leading) {
                                Text("SIP server domain (with port)")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                TextField("For example: sip.example.com:5060", text: $domain)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            
                            // User name
                            VStack(alignment: .leading) {
                                Text("User name")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                TextField("Your SIP user name", text: $username)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            
                            // Password
                            VStack(alignment: .leading) {
                                Text("Password")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                SecureField("Your password", text: $password)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Hint for the user
                        VStack {
                            Text("Dial 22 to call from the intercom")
                                .padding()
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)
                        
                        // Sign-in button
                        Button(action: {
                            login()
                        }) {
                            HStack {
                                if isLoggingIn {
                                    ProgressView()
                                        .padding(.trailing, 5)
                                }
                                
                                Text(isLoggingIn ? "Connecting…" : "Sign in")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isLoggingIn ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                        .disabled(isLoggingIn || domain.isEmpty || username.isEmpty || password.isEmpty)
                        .padding(.top, 10)
                        .padding(.bottom, 30)
                    }
                    .padding()
                }
            }
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text(alertTitle),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onTapGesture {
                hideKeyboard()
            }
        }
    }
    
    // MARK: - Actions
    
    private func login() {
        // Every field is required.
        guard !domain.isEmpty else {
            showAlert(title: "Error", message: "Enter the SIP server domain")
            return
        }
        
        guard !username.isEmpty else {
            showAlert(title: "Error", message: "Enter the user name")
            return
        }
        
        guard !password.isEmpty else {
            showAlert(title: "Error", message: "Enter the password")
            return
        }
        
        // Show the progress indicator.
        isLoggingIn = true
        
        // Persist the credentials.
        UserDefaults.standard.set(domain.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "domain")
        UserDefaults.standard.set(username, forKey: "username")
        UserDefaults.standard.set(password, forKey: "password")
        UserDefaults.standard.set(true, forKey: "isLoggedIn")

        DispatchQueue.global(qos: .userInitiated).async {
            let status = self.calls.configurePJSIP()
            if status != 0 {
                print("❌ SIP configuration failed after login: \(status)")
            }
        }
        
        // Tell the rest of the app that a session exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.Name("LoginNotification"), object: nil)
            isLoggingIn = false
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - LoginHostingController
class LoginHostingController: UIHostingController<LoginView> {
    override init(rootView: LoginView) {
        super.init(rootView: rootView)
    }
    
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Preview
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView(calls: AppCallService())
    }
}
