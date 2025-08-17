//
//  ShakeService.swift
//  ShakeService
//
//  Created by Iker Casillas on 8/16/25.
//

import UIKit
import CoreMotion

@MainActor
protocol ShakeService:AnyObject{
    var isEnabled:Bool { get }
    var onShake: (() -> Void)? { get set } //흔들림 콜백
    
    func bind(to responder: UIResponder)//대상 화면/ 뷰 연결
    func unBind()  //연결 해제
    
    @discardableResult
    func setEnabled(_ enalbed: Bool) -> Result<Void, ShakeActivationFailure>
    
    func preflight(responder: UIResponder) -> Result<Void, ShakeActivationFailure>
    func capabilityCheck(responder: UIResponder) -> Result<Void, ShakeActivationFailure>
    
}

enum ShakeActivationFailure: Error {

    case noAccelerometer

    case cannotBecomeFirstResponder(actual: Bool)

    case becomeFirstResponderFailed

    case notInViewHierarchy

    case noWindow

    case sceneInactive(state: UIScene.ActivationState)

    case policyDenied(reason: String)

    case alreadyActive

    case deactivated

    case unknown(String)

}



extension ShakeActivationFailure: LocalizedError {

    var errorDescription: String? {

        switch self {

        case .noAccelerometer: return "가속도 센서를 사용할 수 없습니다."

        case .cannotBecomeFirstResponder(let actual): return "FR 불가 (canBecomeFirstResponder=\(actual))."

        case .becomeFirstResponderFailed: return "becomeFirstResponder() 실패."

        case .notInViewHierarchy: return "뷰가 아직 화면에 없음."

        case .noWindow: return "window를 찾을 수 없음."

        case .sceneInactive(let s): return "씬 비활성: \(s)."

        case .policyDenied(let reason): return "정책 차단: \(reason)"

        case .alreadyActive: return "이미 활성화됨."

        case .deactivated: return "강제 비활성 상태."

        case .unknown(let msg): return "알 수 없는 오류: \(msg)"

        }

    }

}

