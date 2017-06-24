//
//  WKCookieWebView.swift
//  Example
//
//  Created by kofktu on 2017. 6. 24..
//  Copyright © 2017년 Kofktu. All rights reserved.
//

import UIKit
import Foundation
import WebKit

fileprivate class WKCookieProcessPool: WKProcessPool {
    static let pool = WKCookieProcessPool()
}

open class WKCookieWebView: WKWebView {
    
    public weak var wkNavigationDelegate: WKNavigationDelegate?
    public var onCookieStorageUpdateHandler: ((WKCookieWebView) -> Void)?
    
    fileprivate var updatedCookies = [String]()
    
    public init(frame: CGRect, configurationBlock: ((WKWebViewConfiguration) -> Void)? = nil) {
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        let configuration = WKWebViewConfiguration()
        super.init(frame: frame, configuration: configuration)
        configuration.processPool = WKCookieProcessPool.pool
        configuration.userContentController = userContentWithCookies()
        configurationBlock?(configuration)
        navigationDelegate = self
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented, init(frame:configurationBlock:)")
    }
    
    // MARK: - Private
    private func userContentWithCookies() -> WKUserContentController {
        let userContentController = WKUserContentController()
        
        if let cookies = HTTPCookieStorage.shared.cookies {
            let now = Date()
            var cookieString = "var cookieNames = document.cookie.split('; ').map(function(cookie) { return cookie.split('=')[0] } );\n"
            
            for cookie in cookies {
                if let expiresDate = cookie.expiresDate, now.compare(expiresDate) == .orderedDescending {
                    // Expire
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                    continue
                }
                
                cookieString += "if (cookieNames.indexOf('\(cookie.name)') == -1) { document.cookie='\(cookie.name)=\(cookie.value);domain=\(cookie.domain);path=\(cookie.path);'; };\n"
                updatedCookies.append(cookie.name)
            }
            
            userContentController.addUserScript(WKUserScript(source: cookieString, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        
        return userContentController
        
    }
    
    fileprivate func update(webView: WKWebView) {
        webView.evaluateJavaScript("document.cookie;") { [weak self] (result, error) in
            guard let documentCookie = result as? String else {
                return
            }
            
            DispatchQueue.global(qos: .background).async(execute: {
                guard let `self` = self else {
                    return
                }
                
                let cookieValues = documentCookie.components(separatedBy: "; ")
                
                for value in cookieValues {
                    let comps = value.components(separatedBy: "=")
                    if comps.count < 2 { continue }
                    
                    let localCookie = HTTPCookieStorage.shared.cookies?.filter { $0.name == comps[0] }.first
                    
                    if let localCookie = localCookie {
                        if !comps[1].isEmpty && localCookie.value != comps[1] {
                            // cookie value is different
                            if self.updatedCookies.contains(localCookie.name) {
                                webView.evaluateJavaScript("document.cookie='\(localCookie.name)=\(localCookie.value);domain=\(localCookie.domain);path=\(localCookie.path);'", completionHandler: nil)
                            } else {
                                // set cookie
                                var properties: [HTTPCookiePropertyKey: Any] = [
                                    .name: localCookie.name,
                                    .value: comps[1],
                                    .domain: localCookie.domain,
                                    .path: "/"
                                ]
                                
                                if let expireDate = localCookie.expiresDate {
                                    properties[.expires] = expireDate
                                }
                                
                                if let cookie = HTTPCookie(properties: properties) {
                                    HTTPCookieStorage.shared.setCookie(cookie)
                                    self.onCookieStorageUpdateHandler?(self)
                                }
                            }
                        }
                    } else {
                        if let rootDomain = webView.url?.host, !comps[0].isEmpty && !comps[1].isEmpty {
                            let properties: [HTTPCookiePropertyKey: Any] = [
                                .name: comps[0],
                                .value: comps[1],
                                .domain: rootDomain,
                                .path: "/",
                            ]
                            
                            if let cookie = HTTPCookie(properties: properties) {
                                // set cookie
                                HTTPCookieStorage.shared.setCookie(cookie)
                                self.onCookieStorageUpdateHandler?(self)
                            }
                        }
                    }
                }
            })
        }
    }
    
    fileprivate func update(cookies: [HTTPCookie]?) {
        cookies?.forEach {
            HTTPCookieStorage.shared.setCookie($0)
            updatedCookies.append($0.name)
        }
        
        onCookieStorageUpdateHandler?(self)
    }
}


extension WKCookieWebView: WKNavigationDelegate {
    
    // MARK: - WKNavigationDelegate
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Swift.Void) {
        if let function = wkNavigationDelegate?.webView?(_:decidePolicyFor:decisionHandler:) {
            wkNavigationDelegate?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Swift.Void) {
        defer {
            decisionHandler(.allow)
            wkNavigationDelegate?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
        }
        
        guard let response = navigationResponse.response as? HTTPURLResponse,
            let allHeaderFields = response.allHeaderFields as? [String: String],
            let url = response.url else {
                return
        }
        
        update(cookies: HTTPCookie.cookies(withResponseHeaderFields: allHeaderFields, for: url))
    }
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        wkNavigationDelegate?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    
    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        wkNavigationDelegate?.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        wkNavigationDelegate?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        update(webView: webView)
        wkNavigationDelegate?.webView?(webView, didCommit: navigation)
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        wkNavigationDelegate?.webView?(webView, didFinish: navigation)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        wkNavigationDelegate?.webView?(webView, didFail: navigation, withError: error)
    }
    
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Swift.Void) {
        wkNavigationDelegate?.webView?(webView, didReceive: challenge, completionHandler: completionHandler)
    }
    
    
    @available(iOS 9.0, *)
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        wkNavigationDelegate?.webViewWebContentProcessDidTerminate?(webView)
    }
    
}
