import Foundation

enum TimeGreetingPolicy {
    static func message(at date: Date, calendar: Calendar = .current) -> String {
        message(hour: calendar.component(.hour, from: date))
    }

    static func message(hour: Int) -> String {
        switch hour {
        case 5..<9:
            "早上好，新的一天慢慢来。"
        case 9..<12:
            "上午好，记得喝口水。"
        case 12..<18:
            "下午好，忙里也要休息片刻。"
        case 18..<23:
            "晚上好，愿你享受此刻。"
        default:
            "夜深了，早点睡觉。"
        }
    }
}
