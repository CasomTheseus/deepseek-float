import Foundation

/// 无头自检：`DeepSeekFloat --selftest`
///
/// 用来在不打开窗口的情况下验证两条数据通路到底通不通，以及 WAF 头是否装对了。
/// 只打印结论与脱敏后的数字，绝不打印任何密钥。
///
///   DSF_API_KEY=sk-…        DeepSeekFloat --selftest          # 只测余额
///   DSF_USER_TOKEN=…        DeepSeekFloat --selftest          # 顺带测用量
///   DSF_API_KEY=… DSF_USER_TOKEN=dummy DeepSeekFloat --selftest
///                                                            # 用假令牌探 WAF 是否放行
enum SelfTest {

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let store = CredentialStore.shared

        let apiKey = (env["DSF_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }) ?? store.apiKey
        let userToken = (env["DSF_USER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }) ?? store.userToken

        let keySummary = apiKey.isEmpty ? "缺失" : "存在（\(apiKey.prefix(6))…，长度 \(apiKey.count)）"
        let tokenSummary = userToken.isEmpty ? "缺失" : "存在（长度 \(userToken.count)）"

        print("── DeepSeek 悬浮窗 自检 ──")
        print("凭据文件：\(store.fileURL.path)")
        print("API Key ：\(keySummary)")
        print("平台令牌：\(tokenSummary)")
        print("")

        var failures = 0

        // ① 余额
        print("[1/3] 官方余额接口 api.deepseek.com/user/balance")
        if apiKey.isEmpty {
            print("      ⊘ 跳过：没有 API Key")
        } else {
            do {
                let snapshot = try await DeepSeekAPI.fetchBalance(apiKey: apiKey)
                let text = snapshot.infos.map {
                    "\($0.currency) 总额 \(String(format: "%.2f", $0.total)) = 充值 \(String(format: "%.2f", $0.toppedUp)) + 赠送 \(String(format: "%.2f", $0.granted))"
                }.joined(separator: " | ")
                print("      ✓ 可用=\(snapshot.isAvailable)  \(text)")
            } catch {
                failures += 1
                print("      ✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }

        // ② 平台用量：时间窗口
        print("[2/3] 平台用量接口 usage/by_api_key/amount + cost（窗口）")
        if userToken.isEmpty {
            print("      ⊘ 跳过：没有平台令牌")
        } else {
            do {
                let snapshot = try await DeepSeekAPI.fetchWindowUsage(userToken: userToken, range: .last30d)
                let t = snapshot.totals
                print("      ✓ 30天：命中 \(t.cacheHit) / 未命中 \(t.cacheMiss) / 输出 \(t.output) / 请求 \(t.requests)")
                print("        命中率 \(Fmt.percent(t.cacheHitRate))，费用 \(String(format: "%.4f", snapshot.cost)) \(snapshot.currency)，分桶 \(snapshot.buckets.count) 个，模型 \(snapshot.models.count) 个")
                if snapshot.isEmpty {
                    print("        ⚠︎ 解析出来是空的：接口通了但字段没抓到，解析器需要跟着平台调整")
                }
            } catch let error as DSFloatError {
                if case .invalidUserToken = error {
                    // 这正是「WAF 放行、只是令牌不对」的证据 —— 说明请求头是有效的
                    print("      ✓ WAF 已放行，平台按业务错误正常应答：\(error.errorDescription ?? "")")
                } else {
                    failures += 1
                    print("      ✗ \(error.errorDescription ?? "\(error)")")
                }
            } catch {
                failures += 1
                print("      ✗ \(error)")
            }
        }

        // ③ 平台用量：月度（分模型）
        print("[3/3] 平台用量接口 usage/amount + cost（月度，含分模型）")
        if userToken.isEmpty {
            print("      ⊘ 跳过：没有平台令牌")
        } else {
            do {
                let snapshot = try await DeepSeekAPI.fetchMonthlyUsage(userToken: userToken)
                print("      ✓ 本月：命中 \(snapshot.totals.cacheHit) / 未命中 \(snapshot.totals.cacheMiss) / 输出 \(snapshot.totals.output) / 请求 \(snapshot.totals.requests)")
                print("        费用 \(String(format: "%.4f", snapshot.cost)) \(snapshot.currency)")
                for model in snapshot.models.prefix(8) {
                    print("        · \(model.model)：\(model.breakdown.totalTokens) tokens，\(String(format: "%.4f", model.cost))")
                }
            } catch let error as DSFloatError {
                if case .invalidUserToken = error {
                    print("      ✓ WAF 已放行，平台按业务错误正常应答：\(error.errorDescription ?? "")")
                } else {
                    failures += 1
                    print("      ✗ \(error.errorDescription ?? "\(error)")")
                }
            } catch {
                failures += 1
                print("      ✗ \(error)")
            }
        }

        print("")
        print(failures == 0 ? "结果：没有硬失败。" : "结果：\(failures) 项失败。")
    }
}
