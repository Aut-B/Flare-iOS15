import Foundation
import CryptoKit

/// 微信读书 Web 接口的签名与正文解密。
///
/// 这几段算法是网页端 JS 里的原样移植：正文接口 `/web/book/chapter/e_*`
/// 要求 body 带 `s`（对排序后的 key=value 串做位运算哈希），响应还要过一层
/// 字符重排 + base64。算法本身是纯整数运算，不需要跑 JS，直接搬过来就行。
///
/// 只要有一天腾讯改算法，正文会返回空字符串 —— 那时看 `chk` 是不是校验失败。
enum WereadCrypto {
    // MARK: - MD5

    static func md5(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - calcHash
    //
    // 书籍 id / 章节 uid 都要先过这一层再放进请求体。规则是：
    // md5 前 3 位 + "3"(纯数字) / "4"(其他) + "2" + md5 后 2 位
    // + 分块十六进制（块之间用 "g" 隔开，块前面是块长度）+ 补足 20 位 + md5 前 3 位。
    static func calcHash(_ input: String) -> String {
        let digest = md5(input)
        var result = String(digest.prefix(3))

        let kind: String
        var chunks: [String] = []

        if !input.isEmpty, input.allSatisfy({ $0.isNumber }) {
            kind = "3"
            // 每 9 位切成一段，按十进制读出来再转十六进制。
            var index = input.startIndex
            while index < input.endIndex {
                let end = input.index(index, offsetBy: 9, limitedBy: input.endIndex) ?? input.endIndex
                let chunk = String(input[index..<end])
                chunks.append(String(UInt64(chunk) ?? 0, radix: 16))
                index = end
            }
        } else {
            kind = "4"
            var hex = ""
            for unit in input.utf16 {
                hex += String(unit, radix: 16)
            }
            chunks = [hex]
        }

        result += kind
        result += "2" + String(digest.suffix(2))

        for (offset, chunk) in chunks.enumerated() {
            var lengthHex = String(chunk.count, radix: 16)
            if lengthHex.count == 1 { lengthHex = "0" + lengthHex }
            result += lengthHex
            result += chunk
            if offset < chunks.count - 1 { result += "g" }
        }

        if result.count < 20 {
            result += String(digest.prefix(20 - result.count))
        }

        return result + String(md5(result).prefix(3))
    }

    // MARK: - sign

    /// 对 `key=value` 串做微信读书的位运算哈希，输出小写十六进制。
    static func sign(_ fields: [(String, String)]) -> String {
        let sorted = fields.sorted { $0.0 < $1.0 }
        var query = ""
        for (key, value) in sorted {
            query += key + "=" + encodeURIComponent(value) + "&"
        }
        if query.hasSuffix("&") { query.removeLast() }
        return rawSign(query)
    }

    private static func rawSign(_ data: String) -> String {
        var n1: Int32 = 0x1505_1505
        var n2: Int32 = 0x1505_1505
        let units = Array(data.utf16)
        let length = units.count

        var index = length - 1
        while index > 0 {
            let shift1 = Int32((length - index) % 30)
            n1 = 0x7fff_ffff & (n1 ^ shl(Int32(units[index]), shift1))
            let shift2 = Int32(index % 30)
            n2 = 0x7fff_ffff & (n2 ^ shl(Int32(units[index - 1]), shift2))
            index -= 2
        }

        // JS 里 n1 + n2 是 Number 相加，可能超过 Int32，所以用 Int64 累加。
        let sum = Int64(n1) + Int64(n2)
        return String(sum, radix: 16).lowercased()
    }

    /// 复刻 JS 的 `a << b`：先转 Int32，移位量取低 5 位。
    private static func shl(_ value: Int32, _ shift: Int32) -> Int32 {
        let shifted = UInt32(bitPattern: value) << (UInt32(bitPattern: shift) & 31)
        return Int32(bitPattern: shifted)
    }

    /// JS 的 encodeURIComponent 不编码 `A-Za-z0-9-_.!~*'()`。
    private static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 响应校验与解密

    /// 响应前 32 位是大写 md5(body)，对不上说明内容被截断或接口变了。
    static func chk(_ data: String) -> String {
        guard data.count > 32 else { return data }
        let header = String(data.prefix(32))
        let body = String(data.dropFirst(32))
        return header == md5(body).uppercased() ? body : ""
    }

    /// 去掉首字符 → 按尾部字符推出的位置做两两交换 → base64 解码。
    static func decrypt(_ data: String) -> String {
        guard data.count > 1 else { return "" }
        var result = String(data.dropFirst())
        let positions = swapPositions(result)
        result = swapCharacters(result, positions)
        return base64Decode(result)
    }

    private static func swapPositions(_ value: String) -> [Int] {
        let units = Array(value.utf16)
        let length = units.count
        if length < 4 { return [] }
        if length < 11 { return [0, 2] }

        let tail = min(4, Int(ceil(Double(length) / 10.0)))
        var digits: [Character] = []
        var index = length - 1
        while index > length - 1 - tail {
            // charCode 的二进制写法当四进制读。
            var number = 0
            for character in String(units[index], radix: 2) {
                guard let digit = character.wholeNumberValue else { continue }
                number = number * 4 + digit
            }
            digits.append(contentsOf: String(number))
            index -= 1
        }

        let modulus = length - tail - 2
        guard modulus > 0 else { return [] }
        let width = String(modulus).count
        var result: [Int] = []
        var cursor = 0
        while result.count < 10, cursor + width < digits.count {
            let first = readNumber(digits, from: cursor, width: width)
            result.append(first % modulus)
            let second = readNumber(digits, from: cursor + 1, width: width)
            result.append(second % modulus)
            cursor += width
        }
        return result
    }

    private static func readNumber(_ digits: [Character], from start: Int, width: Int) -> Int {
        var value = 0
        var index = start
        while index < start + width, index < digits.count {
            guard let digit = digits[index].wholeNumberValue else { break }
            value = value * 10 + digit
            index += 1
        }
        return value
    }

    private static func swapCharacters(_ value: String, _ positions: [Int]) -> String {
        guard positions.count >= 2 else { return value }
        var characters = Array(value)
        var index = positions.count - 1
        while index >= 1 {
            for offset in stride(from: 1, through: 0, by: -1) {
                let first = positions[index] + offset
                let second = positions[index - 1] + offset
                if first >= 0, first < characters.count, second >= 0, second < characters.count {
                    characters.swapAt(first, second)
                }
            }
            index -= 2
        }
        return String(characters)
    }

    private static func base64Decode(_ value: String) -> String {
        guard let data = Data(base64Encoded: value) else { return value }
        return String(data: data, encoding: .utf8) ?? value
    }
}
