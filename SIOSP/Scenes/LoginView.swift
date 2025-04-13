import SwiftUI

struct LoginView: View {
    @State private var domain: String = "158.160.5.119:5567"
    @State private var username: String = "412016022"
    @State private var password: String = "AbrakadabrA%4#"
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
                        // Заголовок
                        VStack {
                            Text("Мажордом Звонилка")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .padding(.top, 30)
                            
                            Text("Введите данные для подключения к SIP")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 10)
                        }
                        
                        // Форма входа
                        VStack(spacing: 15) {
                            // Домен SIP сервера
                            VStack(alignment: .leading) {
                                Text("Домен SIP сервера (с портом)")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                TextField("Например: sip.example.com:5060", text: $domain)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            
                            // Имя пользователя
                            VStack(alignment: .leading) {
                                Text("Логин")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                TextField("Ваше имя пользователя SIP", text: $username)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            
                            // Пароль
                            VStack(alignment: .leading) {
                                Text("Пароль")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                SecureField("Ваш пароль", text: $password)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Информация для пользователя
                        VStack {
                            Text("Для звонка с домофона наберите 22")
                                .padding()
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)
                        
                        // Кнопка входа
                        Button(action: {
                            login()
                        }) {
                            HStack {
                                if isLoggingIn {
                                    ProgressView()
                                        .padding(.trailing, 5)
                                }
                                
                                Text(isLoggingIn ? "Подключение..." : "Войти")
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
    
    // MARK: - Функции
    
    private func login() {
        // Проверяем заполнение полей
        guard !domain.isEmpty else {
            showAlert(title: "Ошибка", message: "Введите домен SIP сервера")
            return
        }
        
        guard !username.isEmpty else {
            showAlert(title: "Ошибка", message: "Введите имя пользователя")
            return
        }
        
        guard !password.isEmpty else {
            showAlert(title: "Ошибка", message: "Введите пароль")
            return
        }
        
        // Показываем индикатор загрузки
        isLoggingIn = true
        
        // Сохраняем данные в UserDefaults
        UserDefaults.standard.set(domain.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "domain")
        UserDefaults.standard.set(username, forKey: "username")
        UserDefaults.standard.set(password, forKey: "password")
        UserDefaults.standard.set(true, forKey: "isLoggedIn")
        
        // Отправляем уведомление о входе в систему
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

// MARK: - Предварительный просмотр
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
    }
} 