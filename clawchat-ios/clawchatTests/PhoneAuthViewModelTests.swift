import Foundation
import Testing
@testable import clawchat

struct PhoneAuthViewModelTests {
    @Test func normalizesMainlandPhoneFormats() throws {
        let viewModel = AuthViewModel()

        #expect(viewModel.normalizedMainlandPhone("13800138000") == "13800138000")
        #expect(viewModel.normalizedMainlandPhone("+86 138-0013-8000") == "13800138000")
        #expect(viewModel.normalizedMainlandPhone("008613800138000") == "13800138000")
    }

    @Test func rejectsInvalidMainlandPhone() throws {
        let viewModel = AuthViewModel()

        #expect(viewModel.normalizedMainlandPhone("12800138000") == nil)
        #expect(viewModel.normalizedMainlandPhone("1380013800") == nil)
        #expect(viewModel.normalizedMainlandPhone("hello") == nil)
    }

    @Test func validatesPhoneCodeShape() throws {
        let viewModel = AuthViewModel()
        viewModel.phone = "13800138000"
        viewModel.phoneCode = "12345"

        #expect(viewModel.validatePhoneLogin() == false)
        #expect(viewModel.fieldErrors["phoneCode"] != nil)

        viewModel.phoneCode = "123456"
        #expect(viewModel.validatePhoneLogin() == true)
    }
}
