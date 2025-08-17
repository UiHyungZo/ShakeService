//
//  DefaultShakeService.swift
//  ShakeService
//
//  Created by Iker Casillas on 8/16/25.
//

import UIKit

import CoreMotion

// MARK: - First Responder Detection

private extension UIResponder {
    
    private static weak var _currentFirstResponder: UIResponder?
    
    static func currentFirstResponder() -> UIResponder? {
        
        _currentFirstResponder = nil
        
        UIApplication.shared.sendAction(#selector(_trapCurrentFirstResponder),
                                        
                                        to: nil, from: nil, for: nil)
        
        return _currentFirstResponder
        
    }
    
    @objc private func _trapCurrentFirstResponder() { UIResponder._currentFirstResponder = self }
    
}



// MARK: - Shake Proxy View



private final class ShakeProxyView: UIView {
    
    var onShake: (() -> Void)?
    
    var propagateToSystem = true              // 시스템 기본 동작(Undo 등) 전파 여부
    
    override var canBecomeFirstResponder: Bool { true }
    
    
    
    override func didMoveToWindow() {
        
        super.didMoveToWindow()
        
        isUserInteractionEnabled = false
        
        isHidden = false                       // 숨김 FR 엣지 방지
        
        backgroundColor = .clear
        
        frame = .zero
        
        accessibilityElementsHidden = true
        
        isAccessibilityElement = false
        
    }
    
    
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        
        guard motion == .motionShake else { return super.motionEnded(motion, with: event) }
        
        onShake?()
        
        if propagateToSystem {                 // 시스템 동작(Shake to Undo) 보존 옵션
            
            super.motionEnded(motion, with: event)
            
        }
        
    }
    
}



// MARK: - Enhanced Default Shake Service (슬림 & 견고)



final class EnhancedShakeService: ShakeService {
    
    // State
    
    private let motionManager = CMMotionManager()
    
    private weak var boundResponder: UIResponder?
    
    private weak var hostWindow: UIWindow?
    
    private var shakeProxy: ShakeProxyView?
    
    private(set) var isEnabled: Bool = false
    
    var onShake: (() -> Void)?
    
    
    
    // Policy / Observers
    
    private var policyReason: String?
    
    private var observers: [NSObjectProtocol] = []
    
    
    
    // Throttle
    
    private var lastActivationAttempt: TimeInterval = 0
    
    private let activationThrottle: TimeInterval = 0.1 // 100ms
    
    
    
    // Config
    
    var propagateToSystem: Bool = true                 // 화면별로 전파 제어 가능
    
    
    
    // Init
    
    init(policyReason: String? = nil) { self.policyReason = policyReason }
    
    func setPolicyReason(_ reason: String?) { policyReason = reason }
    
    
    
    deinit {
        
        // nonisolated deinit → 메인에서 안전 정리
        
        let tokens = observers
        
        let pv = shakeProxy
        
        DispatchQueue.main.async {
            
            let nc = NotificationCenter.default
            
            tokens.forEach { nc.removeObserver($0) }
            
            if let v = pv {
                
                if v.isFirstResponder { v.resignFirstResponder() }
                
                v.removeFromSuperview()
                
            }
            
        }
        
    }
    
    
    
    // MARK: - Public
    
    
    
    func bind(to responder: UIResponder) {
        
        if boundResponder != nil { unBind() }
        
        boundResponder = responder
        
        installObserversIfNeeded()
        
        if isEnabled { _ = tryActivate() }
        
    }
    
    
    
    func unBind() {
        
        removeObservers()
        
        deactivateProxy()
        
        boundResponder = nil
        
        hostWindow = nil
        
    }
    
    
    
    @discardableResult
    
    func setEnabled(_ enabled: Bool) -> Result<Void, ShakeActivationFailure> {
        
        if enabled == isEnabled, enabled { return tryActivate() }
        
        if enabled {
            
            installObserversIfNeeded()
            
            let r = tryActivate()
            
            isEnabled = r.isSuccess
            
            return r
            
        } else {
            
            removeObservers()
            
            deactivateProxy()
            
            isEnabled = false
            
            return .success(())
            
        }
        
    }
    
    
    
    // MARK: - Checks
    
    
    
    func preflight(responder: UIResponder) -> Result<Void, ShakeActivationFailure> {
        
        guard isAccelerometerSupported else { return .failure(.noAccelerometer) }
        
        guard let window = findWindow(for: responder) else { return .failure(.noWindow) }
        
        if let scene = window.windowScene, scene.activationState != .foregroundActive {
            
            return .failure(.sceneInactive(state: scene.activationState))
            
        }
        
        if let reason = policyReason { return .failure(.policyDenied(reason: reason)) }
        
        return .success(())
        
    }
    
    
    
    func capabilityCheck(responder: UIResponder) -> Result<Void, ShakeActivationFailure> {
        
        guard isAccelerometerSupported else { return .failure(.noAccelerometer) }
        
        guard let window = findWindow(for: responder) else { return .failure(.noWindow) }
        
        if let scene = window.windowScene, scene.activationState != .foregroundActive {
            
            return .failure(.sceneInactive(state: scene.activationState))
            
        }
        
        return .success(())
        
    }
    
    
    
    // MARK: - Activation
    
    
    
    @discardableResult
    
    private func tryActivate() -> Result<Void, ShakeActivationFailure> {
        
        // throttle
        
        let now = CFAbsoluteTimeGetCurrent()
        
        guard now - lastActivationAttempt >= activationThrottle else { return .success(()) }
        
        lastActivationAttempt = now
        
        
        
        guard let target = boundResponder else { return .failure(.unknown("responder 미지정")) }
        
        
        
        // 텍스트 입력 중이면 FR 탈취 안 함 (조용히 통과 → 이후 rearmSoon / 옵저버로 복구)
        
        if isTextInputActive() { return .success(()) }
        
        
        
        switch preflight(responder: target) {
            
        case .failure(let reason): return .failure(reason)
            
        case .success: break
            
        }
        
        
        
        guard let window = findWindow(for: target) else { return .failure(.noWindow) }
        
        let r = setupProxy(in: window)
        
        if r.isSuccess { hostWindow = window }
        
        return r
        
    }
    
    
    
    private func setupProxy(in window: UIWindow) -> Result<Void, ShakeActivationFailure> {
        
        if let existing = shakeProxy, existing.window !== window {
            
            existing.removeFromSuperview()
            
            shakeProxy = nil
            
        }
        
        
        
        let proxy: ShakeProxyView
        
        if let existing = shakeProxy {
            
            proxy = existing
            
        } else {
            
            let v = ShakeProxyView(frame: .zero)
            
            v.onShake = { [weak self] in
                
                guard let self else { return }
                
                self.onShake?()     // 사용자 콜백
                
                self.rearmSoon()    // 한 번 처리 후 곧바로 FR 재확보 시도
                
            }
            
            v.propagateToSystem = propagateToSystem
            
            window.addSubview(v)
            
            shakeProxy = v
            
            proxy = v
            
        }
        
        
        
        return acquireFirstResponder(for: proxy)
        
    }
    
    
    
    private func acquireFirstResponder(for proxy: ShakeProxyView) -> Result<Void, ShakeActivationFailure> {
        
        // 1차 시도
        
        if proxy.becomeFirstResponder() { return .success(()) }
        
        
        
        // 2차 시도: 다음 런루프에서 비동기 재시도 (main.sync 금지 → 데드락)
        
        RunLoop.main.perform {
            
            _ = proxy.becomeFirstResponder()
            
        }
        
        
        
        // 낙관적으로 성공 처리 (대부분 다음 틱에서 확보됨)
        
        return .success(())
        
    }
    
    
    
    private func rearmSoon() {
        
        RunLoop.main.perform { [weak self] in
            
            guard let self, self.isEnabled else { return }
            
            _ = self.tryActivate()
            
        }
        
    }
    
    
    
    private func deactivateProxy() {
        
        guard let proxy = shakeProxy else { return }
        
        if proxy.isFirstResponder { proxy.resignFirstResponder() }
        
        proxy.removeFromSuperview()
        
        shakeProxy = nil
        
    }
    
    
    
    // MARK: - Observers (최소 2개만)
    
    
    
    private func installObserversIfNeeded() {
        
        guard observers.isEmpty else { return }
        
        let nc = NotificationCenter.default
        
        observers.append(
            
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                
                guard let self, self.isEnabled else { return }
                
                _ = self.tryActivate()
                
            }
            
        )
        
        observers.append(
            
            nc.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                
                guard let self, self.isEnabled else { return }
                
                _ = self.tryActivate()
                
            }
            
        )
        
    }
    
    
    
    private func removeObservers() {
        
        let nc = NotificationCenter.default
        
        observers.forEach { nc.removeObserver($0) }
        
        observers.removeAll()
        
    }
    
    
    
    // MARK: - Utils
    
    
    
    private var isAccelerometerSupported: Bool {
        
        #if targetEnvironment(simulator)
        
        return true
        
        #else
        
        return motionManager.isAccelerometerAvailable
        
        #endif
        
    }
    
    
    
    private func isTextInputActive() -> Bool {
        
        guard let fr = UIResponder.currentFirstResponder() as? NSObject else { return false }
        
        return fr.conforms(to: UIKeyInput.self)
        
    }
    
    
    
    private func findWindow(for responder: UIResponder) -> UIWindow? {
        
        if let vc = responder as? UIViewController, let w = vc.viewIfLoaded?.window { return w }
        
        if let v  = responder as? UIView, let w = v.window { return w }
        
        return findActiveKeyWindow()
        
    }
    
    
    
    private func findActiveKeyWindow() -> UIWindow? {
        
        UIApplication.shared.connectedScenes
        
            .compactMap { $0 as? UIWindowScene }
        
            .first(where: { $0.activationState == .foregroundActive })?
        
            .windows.first(where: { $0.isKeyWindow })
        
    }
    
}


// MARK: - Result helper



private extension Result {
    
    var isSuccess: Bool { if case .success = self { return true } ; return false }
    
}


