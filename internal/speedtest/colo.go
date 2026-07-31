package speedtest

import "strings"

// convertColoToName 将 Cloudflare Colo 代码转换为中文名称（移植自原 core.sh）。
func convertColoToName(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	switch code {
	// 亚太地区
	case "HKG":
		return "香港"
	case "NRT", "TYO":
		return "东京"
	case "ICN":
		return "首尔"
	case "SIN":
		return "新加坡"
	case "TPE":
		return "台北"
	case "KUL":
		return "吉隆坡"
	case "BKK":
		return "曼谷"
	case "MNL":
		return "马尼拉"
	// 北美地区
	case "LAX":
		return "洛杉矶"
	case "SJC":
		return "圣何塞"
	case "SEA":
		return "西雅图"
	case "LAS":
		return "拉斯维加斯"
	case "DEN":
		return "丹佛"
	case "MIA":
		return "迈阿密"
	case "YVR":
		return "温哥华"
	case "YYZ":
		return "多伦多"
	case "YUL":
		return "蒙特利尔"
	case "IAD":
		return "华盛顿"
	case "ORD":
		return "芝加哥"
	case "DFW":
		return "达拉斯"
	case "ATL":
		return "亚特兰大"
	// 欧洲地区
	case "LON", "LHR":
		return "伦敦"
	case "FRA":
		return "法兰克福"
	case "AMS":
		return "阿姆斯特丹"
	case "CDG":
		return "巴黎"
	case "MAD":
		return "马德里"
	case "MXP":
		return "米兰"
	case "ZRH":
		return "苏黎世"
	case "VIE":
		return "维也纳"
	case "WAW":
		return "华沙"
	case "PRG":
		return "布拉格"
	case "BUD":
		return "布达佩斯"
	case "ARN":
		return "斯德哥尔摩"
	case "IST":
		return "伊斯坦布尔"
	// 中东和南亚
	case "DXB":
		return "迪拜"
	case "BOM":
		return "孟买"
	case "DEL":
		return "德里"
	// 大洋洲
	case "SYD":
		return "悉尼"
	case "MEL":
		return "墨尔本"
	case "AKL":
		return "奥克兰"
	// 南美
	case "GRU":
		return "圣保罗"
	case "GIG":
		return "里约热内卢"
	case "EZE":
		return "布宜诺斯艾利斯"
	case "SCL":
		return "圣地亚哥"
	case "BOG":
		return "波哥大"
	case "LIM":
		return "利马"
	// 北美（墨西哥）
	case "QRO":
		return "克雷塔罗"
	case "MEX":
		return "墨西哥城"
	default:
		return code // 未知代码，返回原值
	}
}
