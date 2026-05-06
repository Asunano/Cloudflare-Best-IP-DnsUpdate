# Cloudflare-Best-IP-DnsUpdate 标准数据格式规范

## 概述

本文档定义了模块间数据交换的标准格式，确保各模块之间的兼容性和稳定性。

---

## 1. 标准 IP 列表格式 (.iplist)

### 1.1 格式定义

```
# 注释行以 # 开头
# 每行格式: IP|延迟|下载速度|地区码
# 字段分隔符: | (竖线)
# 编码: UTF-8
# 换行符: LF (\n) 或 CRLF (\r\n)
```

### 1.2 示例文件

```iplist
# Cloudflare 优选 IP 列表
# 生成时间: 2026-05-06 09:30:00
# 测速节点: HKG,NRT
# 总IP数: 5

# IP地址|延迟(ms)|下载速度(MB/s)|地区码
104.16.132.229|45|12.5|HKG
104.16.133.229|48|11.8|NRT
104.16.134.229|52|10.2|HKG
104.16.135.229|55|9.8|SIN
104.16.136.229|58|9.5|TYO
```

### 1.3 字段说明

| 字段 | 类型 | 必填 | 说明 | 示例 |
|------|------|------|------|------|
| IP地址 | String | ✅ | IPv4 地址 | `104.16.132.229` |
| 延迟 | Integer | ✅ | 平均延迟（毫秒） | `45` |
| 下载速度 | Float | ✅ | 下载速度（MB/s） | `12.5` |
| 地区码 | String | ✅ | Cloudflare Colo 代码 | `HKG` |

### 1.4 兼容性规则

- **向后兼容**：旧格式的 `.txt` 文件（纯IP列表）仍可被识别
- **自动转换**：模块应支持从旧格式自动转换为新格式
- **容错处理**：遇到无效行应跳过并记录警告，不中断处理

---

## 2. 当前数据流转

### 2.1 完整流程

```
┌─────────────────┐
│ cf-ip/core.sh   │
│ 测速程序         │
└────────┬────────┘
         │
         │ 输出: result.csv (CSV格式)
         │ 格式: IP,已发送,已接收,丢包率,延迟,速度,地区码
         ▼
┌─────────────────┐
│ ip-sync/sync.sh │
│ IP同步模块       │
└────────┬────────┘
         │
         │ 读取: result.csv
         │ 输出: ip_list.txt (纯文本)
         │ 格式: 每行一个IP
         ▼
┌─────────────────┐
│ cf-dns/core.sh  │
│ DNS更新模块      │
└─────────────────┘
         │
         │ 读取: ip_list.txt
         │ 提取IP列表用于DNS更新
```

### 2.2 问题点

1. **格式不统一**：CSV → TXT → IP List，三次格式转换
2. **信息丢失**：TXT 格式只保留 IP，丢失延迟、速度等元数据
3. **耦合度高**：任何一环格式变化都会导致下游断裂
4. **难以扩展**：无法添加新的字段（如更新时间、质量评分等）

---

## 3. 迁移方案

### 3.1 阶段一：引入 .iplist 格式（当前）

**目标**：定义标准格式，提供转换工具

**实施**：
1. 在 `cf-ip/core.sh` 中添加 `.iplist` 导出功能
2. 在 `ip-sync/sync.sh` 中添加格式转换函数
3. 在 `cf-dns/core.sh` 中支持读取 `.iplist` 格式

**兼容性**：
- ✅ 保留原有的 CSV 和 TXT 格式支持
- ✅ 新增 `.iplist` 作为推荐格式
- ✅ 提供自动检测和转换机制

---

### 3.2 阶段二：逐步迁移（未来）

**目标**：所有模块默认使用 `.iplist` 格式

**实施**：
1. 修改配置文件，默认使用 `.iplist` 路径
2. 弃用 TXT 格式，标记为 "deprecated"
3. 移除 CSV 到 TXT 的中间转换步骤

**时间线**：建议在下一个大版本（v2.0）中实施

---

## 4. 转换工具

### 4.1 CSV → .iplist

```bash
# 从 cfst CSV 转换为标准 .iplist 格式
csv_to_iplist() {
    local csv_file="$1"
    local iplist_file="$2"
    
    echo "# Cloudflare 优选 IP 列表" > "$iplist_file"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$iplist_file"
    echo "#" >> "$iplist_file"
    echo "# IP地址|延迟(ms)|下载速度(MB/s)|地区码" >> "$iplist_file"
    
    # 跳过 CSV 标题行，提取需要的字段
    tail -n +2 "$csv_file" | while IFS=',' read -r ip sent recv loss delay speed region; do
        # 清理 Windows 换行符
        region=$(echo "$region" | tr -d '\r')
        
        # 只保留有效数据（速度 > 0）
        if [[ "$speed" =~ ^[0-9.]+$ ]] && (( $(echo "$speed > 0" | bc -l) )); then
            echo "${ip}|${delay}|${speed}|${region}" >> "$iplist_file"
        fi
    done
}
```

### 4.2 .iplist → TXT（兼容旧模块）

```bash
# 从 .iplist 提取纯 IP 列表（兼容旧模块）
iplist_to_txt() {
    local iplist_file="$1"
    local txt_file="$2"
    
    # 提取第一列（IP地址），跳过注释行
    grep -v '^#' "$iplist_file" | awk -F'|' '{print $1}' > "$txt_file"
}
```

### 4.3 TXT → .iplist（补充元数据）

```bash
# 从纯 TXT 升级为 .iplist（需要重新测速获取元数据）
txt_to_iplist() {
    local txt_file="$1"
    local iplist_file="$2"
    
    echo "# 注意: 此文件由 TXT 格式升级而来" > "$iplist_file"
    echo "# 延迟、速度、地区码字段为默认值，建议重新测速" >> "$iplist_file"
    echo "#" >> "$iplist_file"
    echo "# IP地址|延迟(ms)|下载速度(MB/s)|地区码" >> "$iplist_file"
    
    while IFS= read -r ip; do
        # 跳过空行和注释
        [[ -z "$ip" ]] && continue
        [[ "$ip" =~ ^# ]] && continue
        
        # 使用默认值（因为 TXT 格式不包含这些信息）
        echo "${ip}|0|0.0|UNKNOWN" >> "$iplist_file"
    done < "$txt_file"
}
```

---

## 5. 最佳实践

### 5.1 模块开发规范

1. **优先使用 .iplist 格式**
   ```bash
   # 推荐
   IP_FILE="./assets/data/cf-dns/ip_list.iplist"
   
   # 不推荐（仅用于兼容）
   IP_FILE="./assets/data/cf-dns/ip_list.txt"
   ```

2. **支持多种格式自动检测**
   ```bash
   detect_ip_format() {
       local file="$1"
       
       if [[ "$file" == *.iplist ]]; then
           echo "iplist"
       elif [[ "$file" == *.csv ]]; then
           echo "csv"
       elif [[ "$file" == *.txt ]]; then
           echo "txt"
       else
           # 根据内容判断
           if head -n 1 "$file" | grep -q '|'; then
               echo "iplist"
           elif head -n 1 "$file" | grep -q ','; then
               echo "csv"
           else
               echo "txt"
           fi
       fi
   }
   ```

3. **提供格式转换提示**
   ```bash
   if [[ "$format" == "txt" ]]; then
       log_warn "检测到旧格式 TXT 文件，建议转换为 .iplist 格式以保留更多元数据"
       log_info "转换命令: bash modules/ip-sync/sync.sh --convert $IP_FILE"
   fi
   ```

---

### 5.2 配置文件示例

```json
{
  "ip_source": {
    "type": "file",
    "path": "./assets/data/cf-dns/ip_list.iplist",
    "format": "iplist",
    "auto_convert": true
  }
}
```

---

## 6. 常见问题

### Q1: 为什么要引入新格式？

**A**: 
- 保留更多元数据（延迟、速度、地区码）
- 便于后续分析和优化
- 提高模块间的解耦程度
- 支持更复杂的筛选策略

### Q2: 旧格式的 TXT 文件还能用吗？

**A**: 
- ✅ 可以，完全兼容
- ⚠️ 但会丢失元数据
- 💡 建议转换为 `.iplist` 格式

### Q3: 如何批量转换现有文件？

**A**:
```bash
# 转换所有 TXT 文件为 .iplist
for txt_file in ./assets/data/*/ip_list.txt; do
    iplist_file="${txt_file%.txt}.iplist"
    bash modules/ip-sync/sync.sh --convert "$txt_file" "$iplist_file"
done
```

### Q4: .iplist 文件大小会增加多少？

**A**:
- TXT 格式：每行约 15 字节（IP地址 + 换行）
- .iplist 格式：每行约 40 字节（IP + 延迟 + 速度 + 地区码 + 分隔符）
- 增加约 2.7 倍，但对于典型配置（5-10个IP），总大小仍小于 1KB

---

## 7. 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0 | 2026-05-06 | 初始版本，定义 .iplist 格式 |

---

## 8. 参考资料

- [Cloudflare Colo Codes](https://www.cloudflare.com/network/)
- [RFC 4180 - CSV Format](https://tools.ietf.org/html/rfc4180)
- [JSON Lines Format](http://jsonlines.org/)
