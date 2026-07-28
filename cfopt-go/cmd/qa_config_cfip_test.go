package cmd

import (
	"testing"
)

// ============================================================================
// F4: CF-IP 参数菜单（config_cfip.go）
// ============================================================================

// TestBuildCFIPParams_returns19 验证 buildCFIPParams 返回恰好 19 个参数。
func TestBuildCFIPParams_returns19(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))
	if len(params) != 19 {
		t.Fatalf("buildCFIPParams 应返回 19 个参数，实际 %d", len(params))
	}

	// 验证前 15 个属于 cfst 段
	for i, p := range params {
		if i < 15 {
			if p.Section != "cfst" {
				t.Errorf("params[%d] (%s) 应属于 cfst 段，实际 %s", i, p.Label, p.Section)
			}
		} else {
			if p.Section != "speed_test" {
				t.Errorf("params[%d] (%s) 应属于 speed_test 段，实际 %s", i, p.Label, p.Section)
			}
		}
	}
}

// TestBuildCFIPParams_indices 验证参数编号从 1 到 19。
func TestBuildCFIPParams_indices(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))
	for i, p := range params {
		if p.Index != i+1 {
			t.Errorf("params[%d].Index = %d，期望 %d", i, p.Index, i+1)
		}
	}
}

// TestBuildCFIPParams_firstParams 验证关键参数的位置和默认值。
func TestBuildCFIPParams_firstParams(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))

	// 线程数
	if params[0].Key != "threads" || params[0].DefaultVal != "200" || params[0].ValueType != "int" {
		t.Errorf("线程数参数异常: %+v", params[0])
	}
	// 端口
	if params[2].Key != "port" || params[2].DefaultVal != "443" || params[2].ValueType != "int" {
		t.Errorf("端口参数异常: %+v", params[2])
	}
	// 地区
	if params[3].Key != "colo" || params[3].DefaultVal != "HKG,NRT" || params[3].ValueType != "string" {
		t.Errorf("地区参数异常: %+v", params[3])
	}
	// 禁用下载测速 (bool)
	if params[11].Key != "disable_download" || params[11].DefaultVal != "false" || params[11].ValueType != "bool" {
		t.Errorf("禁用下载测速参数异常: %+v", params[11])
	}
}

// TestBuildCFIPParams_speedTest 验证 speed_test 段参数。
func TestBuildCFIPParams_speedTest(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))

	// take_ip_num (param 15, 0-based index 15)
	takeIP := params[15]
	if takeIP.Key != "take_ip_num" || takeIP.DefaultVal != "5" || takeIP.ValueType != "int" {
		t.Errorf("take_ip_num 参数异常: %+v", takeIP)
	}
	if takeIP.Section != "speed_test" {
		t.Errorf("take_ip_num 应属于 speed_test 段")
	}

	// max_retry (param 16)
	if params[16].Key != "max_retry" || params[16].DefaultVal != "3" {
		t.Errorf("max_retry 参数异常: %+v", params[16])
	}

	// output_html (param 17, bool)
	if params[17].Key != "output_html" || params[17].DefaultVal != "true" || params[17].ValueType != "bool" {
		t.Errorf("output_html 参数异常: %+v", params[17])
	}

	// enable_log (param 18, bool)
	if params[18].Key != "enable_log" || params[18].DefaultVal != "true" || params[18].ValueType != "bool" {
		t.Errorf("enable_log 参数异常: %+v", params[18])
	}
}

// TestBuildCFIPParams_readsCurrentValues 验证 buildCFIPParams 从配置中读取当前值。
func TestBuildCFIPParams_readsCurrentValues(t *testing.T) {
	cfstSection := map[string]interface{}{
		"threads": 100,
		"port":    8443,
		"colo":    "HKG",
	}
	speedSection := map[string]interface{}{
		"take_ip_num": 10,
	}

	params := buildCFIPParams(cfstSection, speedSection)

	// threads 应读取为 "100" 而非默认 "200"
	if params[0].CurrentVal != "100" {
		t.Errorf("threads.CurrentVal = %q，期望 %q", params[0].CurrentVal, "100")
	}
	// port 应读取为 "8443" 而非默认 "443"
	if params[2].CurrentVal != "8443" {
		t.Errorf("port.CurrentVal = %q，期望 %q", params[2].CurrentVal, "8443")
	}
	// colo 应读取为 "HKG"
	if params[3].CurrentVal != "HKG" {
		t.Errorf("colo.CurrentVal = %q，期望 %q", params[3].CurrentVal, "HKG")
	}
	// take_ip_num 应读取为 "10"
	if params[15].CurrentVal != "10" {
		t.Errorf("take_ip_num.CurrentVal = %q，期望 %q", params[15].CurrentVal, "10")
	}
	// 未设置的值应使用默认
	if params[1].CurrentVal != "4" {
		t.Errorf("ping_times.CurrentVal = %q，期望默认 %q", params[1].CurrentVal, "4")
	}
}

// TestBuildCFIPParams_emptySections 空配置段应全部使用默认值。
func TestBuildCFIPParams_emptySections(t *testing.T) {
	params := buildCFIPParams(nil, nil)
	for _, p := range params {
		if p.CurrentVal != p.DefaultVal {
			t.Errorf("%s.CurrentVal = %q，期望默认 %q", p.Label, p.CurrentVal, p.DefaultVal)
		}
	}
}

// TestFormatValue_bool 验证布尔值格式化。
func TestFormatValue_bool(t *testing.T) {
	tests := []struct {
		val  string
		want string
	}{
		{"true", "true"},
		{"false", "false"},
		{"1", "true"},
		{"0", "false"},
		{"", "(空)"},
	}
	for _, tt := range tests {
		got := formatValue(tt.val, "bool")
		if got != tt.want {
			t.Errorf("formatValue(%q, bool) = %q，期望 %q", tt.val, got, tt.want)
		}
	}
}

// TestFormatValue_int 验证整数格式化。
func TestFormatValue_int(t *testing.T) {
	got := formatValue("200", "int")
	if got != "200" {
		t.Errorf("formatValue(200, int) = %q，期望 %q", got, "200")
	}
	got = formatValue("", "int")
	if got != "(空)" {
		t.Errorf("formatValue('', int) = %q，期望 (空)", got)
	}
}

// TestFormatValue_float 验证浮点数格式化。
func TestFormatValue_float(t *testing.T) {
	got := formatValue("9999", "float")
	if got != "9999" {
		t.Errorf("formatValue(9999, float) = %q，期望 %q", got, "9999")
	}
	got = formatValue("1.00", "float")
	if got != "1.00" {
		t.Errorf("formatValue(1.00, float) = %q，期望 %q", got, "1.00")
	}
}

// TestFormatValue_string 验证字符串格式化。
func TestFormatValue_string(t *testing.T) {
	got := formatValue("HKG,NRT", "string")
	if got != "HKG,NRT" {
		t.Errorf("formatValue(HKG,NRT, string) = %q", got)
	}
	got = formatValue("", "string")
	if got != "(空)" {
		t.Errorf("formatValue('', string) = %q，期望 (空)", got)
	}
}

// TestFormatValue_unknownType 未知类型回退到直接返回值。
func TestFormatValue_unknownType(t *testing.T) {
	got := formatValue("anything", "unknown")
	if got != "anything" {
		t.Errorf("未知类型应直接返回值，got=%q", got)
	}
}

// TestEditCFIPParam_int 验证整数类型参数编辑。
func TestEditCFIPParam_int(t *testing.T) {
	cfstSection := map[string]interface{}{}
	param := &cfipParam{
		Index:      1,
		Section:    "cfst",
		Key:        "threads",
		Label:      "线程数",
		DefaultVal: "200",
		CurrentVal: "200",
		ValueType:  "int",
	}
	editCFIPParam(param, cfstSection, nil)
	// 无交互输入时值不变
	if v, ok := cfstSection["threads"]; ok {
		t.Errorf("无输入时不应对配置做修改，got=%v", v)
	}
}

// TestEditCFIPParam_bool 验证布尔类型参数在非交互环境不修改。
func TestEditCFIPParam_bool(t *testing.T) {
	cfstSection := map[string]interface{}{}
	param := &cfipParam{
		Index:      12,
		Section:    "cfst",
		Key:        "disable_download",
		Label:      "禁用下载测速",
		DefaultVal: "false",
		CurrentVal: "false",
		ValueType:  "bool",
	}
	editCFIPParam(param, cfstSection, nil)
	if v, ok := cfstSection["disable_download"]; ok {
		t.Errorf("无输入时不应对配置做修改，got=%v", v)
	}
}

// TestEditCFIPParam_string 验证字符串类型参数在非交互环境不修改。
func TestEditCFIPParam_string(t *testing.T) {
	cfstSection := map[string]interface{}{}
	param := &cfipParam{
		Index:      4,
		Section:    "cfst",
		Key:        "colo",
		Label:      "地区",
		DefaultVal: "HKG,NRT",
		CurrentVal: "HKG,NRT",
		ValueType:  "string",
	}
	editCFIPParam(param, cfstSection, nil)
	if v, ok := cfstSection["colo"]; ok {
		t.Errorf("无输入时不应对配置做修改，got=%v", v)
	}
}

// TestBuildCFIPParams_allParamKeys 验证全部 19 个参数的 Key 唯一且完整。
func TestBuildCFIPParams_allParamKeys(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))
	keys := make(map[string]bool)
	for _, p := range params {
		if keys[p.Key] {
			t.Errorf("重复的 Key: %s", p.Key)
		}
		keys[p.Key] = true
	}
	expectedKeys := []string{
		"threads", "ping_times", "port", "colo", "url",
		"download_count", "download_time", "latency_max", "packet_loss_max", "speed_min",
		"show_count", "disable_download", "all_ip", "ip_file", "httping",
		"take_ip_num", "max_retry", "output_html", "enable_log",
	}
	for _, k := range expectedKeys {
		if !keys[k] {
			t.Errorf("缺少参数 key: %s", k)
		}
	}
}

// TestBuildCFIPParams_valueTypes 验证所有参数类型正确。
func TestBuildCFIPParams_valueTypes(t *testing.T) {
	params := buildCFIPParams(make(map[string]interface{}), make(map[string]interface{}))
	for _, p := range params {
		switch p.ValueType {
		case "int", "float", "bool", "string":
			// 有效
		default:
			t.Errorf("%s (%s): 无效类型 %q", p.Label, p.Key, p.ValueType)
		}
	}
}
