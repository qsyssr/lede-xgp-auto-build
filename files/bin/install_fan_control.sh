#!/bin/sh

# 清理旧文件防止冲突
echo "清理旧版本文件..."
rm -f /usr/bin/sensors_monitor
rm -f /usr/bin/set_fan_speed
rm -f /usr/bin/fan_control
rm -f /usr/lib/lua/luci/controller/sensors.lua
rm -f /usr/lib/lua/luci/view/sensors_monitor.htm
rm -f /etc/fan_target
rm -f /etc/fan_config
rm -f /etc/init.d/fancontrol

# 创建监控脚本（输出JSON格式）
echo "创建传感器监控脚本..."
cat << 'EOF' > /usr/bin/sensors_monitor
#!/bin/sh

# 采集数据并转换为JSON格式
{
  echo "{"
  
  # CPU温度
  cpu_temp=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null)
  [ -n "$cpu_temp" ] && cpu_temp=$((cpu_temp/1000)) || cpu_temp="N/A"
  echo "\"cpu_temp\": \"$cpu_temp\","
  
  # 5GHz WiFi温度
  wifi5_temp=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort -r | head -1)
  [ -n "$wifi5_temp" ] && wifi5_temp=$((wifi5_temp/1000)) || wifi5_temp="N/A"
  echo "\"wifi5_temp\": \"$wifi5_temp\","
  
  # 2.4GHz WiFi温度
  wifi2_temp=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort | head -1)
  [ -n "$wifi2_temp" ] && wifi2_temp=$((wifi2_temp/1000)) || wifi2_temp="N/A"
  echo "\"wifi2_temp\": \"$wifi2_temp\","
  
  # SSD温度
  ssd_temp=$(smartctl -A /dev/nvme0 2>/dev/null | awk '/Temperature:/ {print $2}')
  [ -n "$ssd_temp" ] || ssd_temp="N/A"
  echo "\"ssd_temp\": \"$ssd_temp\","
  
  # 5G模组温度（优化后的提取方式）
  modem_temp=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | \
               grep -A1 '"key": "temperature"' | \
               grep '"value":' | \
               cut -d'"' -f4 | \
               awk '{print $1}')
  [ -n "$modem_temp" ] || modem_temp="N/A"
  echo "\"modem_temp\": \"$modem_temp\","
  
  # 计算最高温度
  max_temp=0
  for temp in "$cpu_temp" "$wifi5_temp" "$wifi2_temp" "$ssd_temp" "$modem_temp"; do
    if [ "$temp" != "N/A" ] && [ $temp -gt $max_temp ]; then
      max_temp=$temp
    fi
  done
  echo "\"max_temp\": \"$max_temp\","
  
  # 风扇转速 - 转换为百分比
  fan_pwm=$(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
  if [ -n "$fan_pwm" ]; then
    # 假设PWM范围是0-255
    fan_percent=$(( (fan_pwm * 100) / 255 ))
    echo "\"fan_percent\": \"$fan_percent\","
  else
    echo "\"fan_percent\": \"N/A\","
  fi
  
  # 添加风扇目标转速（从配置文件中读取）
  if [ -f "/etc/fan_config" ]; then
    source /etc/fan_config
    echo "\"fan_target_temp\": \"$target_temp\","
    echo "\"fan_mode\": \"$mode\","
    echo "\"kp\": \"$kp\","
    echo "\"ki\": \"$ki\","
    echo "\"kd\": \"$kd\","
    echo "\"cycle\": \"$cycle\""
  else
    echo "\"fan_target_temp\": \"55\","
    echo "\"fan_mode\": \"auto\","
    echo "\"kp\": \"5.0\","
    echo "\"ki\": \"0.1\","
    echo "\"kd\": \"1.0\","
    echo "\"cycle\": \"10\""
  fi
  
  echo "}"
} | tr -d '\n'
EOF
chmod +x /usr/bin/sensors_monitor

# 创建风扇控制脚本（支持手动和自动模式）
echo "创建风扇控制脚本..."
cat << 'EOF' > /usr/bin/set_fan_speed
#!/bin/sh

# 检查参数
if [ -z "$1" ]; then
  echo "Usage: $0 <percentage>"
  exit 1
fi

# 将百分比转换为PWM值 (0-255)
percent=$1
if [ "$percent" -lt 0 ] || [ "$percent" -gt 100 ]; then
  echo "Error: Percentage must be between 0 and 100"
  exit 1
fi

pwm_value=$(( (percent * 255) / 100 ))

# 找到风扇控制文件
fan_file=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 2>/dev/null | head -1)

if [ -n "$fan_file" ] && [ -w "$fan_file" ]; then
  # 写入PWM值
  echo $pwm_value > $fan_file
  echo "Fan speed set to $percent% (PWM: $pwm_value)"
else
  echo "Error: Fan control file not found or not writable"
  exit 1
fi
EOF
chmod +x /usr/bin/set_fan_speed

# 创建温控脚本（PID控制）- 增强强硬性
echo "创建温控脚本..."
cat << 'EOF' > /usr/bin/fan_control
#!/bin/sh

# 加载配置
if [ -f "/etc/fan_config" ]; then
    source /etc/fan_config
else
    # 默认配置
    target_temp=55
    min_speed=20
    max_speed=100
    mode="auto"
    kp=3.5
    ki=0.05
    kd=1.5
    cycle=1
fi

# 获取风扇控制文件路径
FAN_FILE=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 2>/dev/null | head -1)

# 确保风扇控制文件存在并可写
ensure_fan_control() {
    if [ -z "$FAN_FILE" ] || [ ! -w "$FAN_FILE" ]; then
        echo "ERROR: Fan control file not found or not writable"
        exit 1
    fi
}

# 强制设置风扇控制权限
force_fan_control() {
    # 尝试设置权限
    if [ -n "$FAN_FILE" ]; then
        chmod 666 "$FAN_FILE" >/dev/null 2>&1
    else
        # 尝试重新查找风扇文件
        FAN_FILE=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
        if [ -n "$FAN_FILE" ]; then
            chmod 666 "$FAN_FILE" >/dev/null 2>&1
        fi
    fi
    
    # 再次检查
    ensure_fan_control
}

# 初始化时强制获取控制权
force_fan_control

# PID状态变量
last_error=0
integral=0
last_time=$(date +%s)

# 获取最高温度
get_max_temp() {
    # 获取所有温度值
    cpu_temp=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null)
    [ -n "$cpu_temp" ] && cpu_temp=$((cpu_temp/1000)) || cpu_temp=0
    
    wifi5_temp=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort -r | head -1)
    [ -n "$wifi5_temp" ] && wifi5_temp=$((wifi5_temp/1000)) || wifi5_temp=0
    
    wifi2_temp=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort | head -1)
    [ -n "$wifi2_temp" ] && wifi2_temp=$((wifi2_temp/1000)) || wifi2_temp=0
    
    ssd_temp=$(smartctl -A /dev/nvme0 2>/dev/null | awk '/Temperature:/ {print $2}')
    [ -n "$ssd_temp" ] || ssd_temp=0
    
    # 5G模组温度（优化后的提取方式）
    modem_temp=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | \
                 grep -A1 '"key": "temperature"' | \
                 grep '"value":' | \
                 cut -d'"' -f4 | \
                 awk '{print $1}')
    [ -n "$modem_temp" ] || modem_temp=0
    
    # 找出最高温度
    max_temp=$cpu_temp
    [ $wifi5_temp -gt $max_temp ] && max_temp=$wifi5_temp
    [ $wifi2_temp -gt $max_temp ] && max_temp=$wifi2_temp
    [ $ssd_temp -gt $max_temp ] && max_temp=$ssd_temp
    [ $modem_temp -gt $max_temp ] && max_temp=$modem_temp
    
    echo $max_temp
}

# 浮点数计算函数
calc() {
    echo "scale=3; $1" | bc
}

# 主循环
while true; do
    # 每次循环都重新加载配置，确保使用最新的设置
    if [ -f "/etc/fan_config" ]; then
        source /etc/fan_config
    fi
    
    # 每次循环都确保风扇控制权限
    ensure_fan_control || force_fan_control
    
    if [ "$mode" = "auto" ]; then
        current_temp=$(get_max_temp)
        current_time=$(date +%s)
        dt=$((current_time - last_time))
        
        # 确保时间间隔大于0
        if [ $dt -lt 1 ]; then
            dt=1
        fi
        
        # 计算误差
        error=$(calc "$current_temp - $target_temp")
        
        # PID计算
        # 比例项
        P=$(calc "$kp * $error")
        
        # 积分项（带抗饱和）
        integral=$(calc "$integral + $ki * $error * $dt")
        
        # 微分项
        derivative=$(calc "($error - $last_error) / $dt")
        D=$(calc "$kd * $derivative")
        
        # 计算输出
        output=$(calc "$P + $integral + $D")
        
        # 转换为整数
        output_int=$(printf "%.0f" "$output")
        
        # 限制在最小和最大速度之间
        if [ $output_int -lt $min_speed ]; then
            speed=$min_speed
            # 抗积分饱和 - 如果输出饱和则重置积分
            integral=0
        elif [ $output_int -gt $max_speed ]; then
            speed=$max_speed
            # 抗积分饱和
            integral=0
        else
            speed=$output_int
        fi
        
        # 更新状态
        last_error=$error
        last_time=$current_time
        
        # 设置风扇转速
        /usr/bin/set_fan_speed $speed >/dev/null
    fi
    
    # 按配置的周期休眠
    sleep $cycle
done
EOF
chmod +x /usr/bin/fan_control

# 创建LuCI控制器
echo "创建LuCI控制器..."
cat << 'EOF' > /usr/lib/lua/luci/controller/sensors.lua
module("luci.controller.sensors", package.seeall)

function index()
    entry({"admin", "status", "sensors"}, template("sensors_monitor"), _("硬件监控 V1.06"), 90)
    entry({"admin", "status", "sensors", "data"}, call("action_data"))
    entry({"admin", "status", "sensors", "setfan"}, call("action_setfan"))
    entry({"admin", "status", "sensors", "settemp"}, call("action_settemp"))
    entry({"admin", "status", "sensors", "setmode"}, call("action_setmode"))
    entry({"admin", "status", "sensors", "setpid"}, call("action_setpid"))
end

function action_data()
    luci.http.prepare_content("application/json")
    luci.http.write(luci.sys.exec("/usr/bin/sensors_monitor"))
end

function action_setfan()
    local fan_percent = luci.http.formvalue("fan_percent")
    if fan_percent and tonumber(fan_percent) then
        -- 切换到手动模式
        os.execute("sed -i 's/mode=.*/mode=manual/' /etc/fan_config")
        
        local result = luci.sys.exec("/usr/bin/set_fan_speed " .. fan_percent)
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "' .. result:gsub('"', '\\"') .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid fan percentage"}')
    end
end

function action_settemp()
    local target_temp = luci.http.formvalue("target_temp")
    if target_temp and tonumber(target_temp) then
        os.execute("sed -i 's/target_temp=.*/target_temp=" .. target_temp .. "/' /etc/fan_config")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "Target temperature set to ' .. target_temp .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid temperature value"}')
    end
end

function action_setmode()
    local mode = luci.http.formvalue("mode")
    if mode and (mode == "auto" or mode == "manual") then
        os.execute("sed -i 's/mode=.*/mode=" .. mode .. "/' /etc/fan_config")
        
        -- 如果是手动模式，恢复上次手动设置的风扇速度
        if mode == "manual" and luci.http.formvalue("fan_percent") then
            local fan_percent = luci.http.formvalue("fan_percent")
            os.execute("/usr/bin/set_fan_speed " .. fan_percent)
        end
        
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "Mode set to ' .. mode .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid mode"}')
    end
end

function action_setpid()
    local kp = luci.http.formvalue("kp")
    local ki = luci.http.formvalue("ki")
    local kd = luci.http.formvalue("kd")
    local cycle = luci.http.formvalue("cycle")
    
    if kp and tonumber(kp) and ki and tonumber(ki) and kd and tonumber(kd) and cycle and tonumber(cycle) then
        -- 更新配置文件
        os.execute("sed -i 's/kp=.*/kp=" .. kp .. "/' /etc/fan_config")
        os.execute("sed -i 's/ki=.*/ki=" .. ki .. "/' /etc/fan_config")
        os.execute("sed -i 's/kd=.*/kd=" .. kd .. "/' /etc/fan_config")
        os.execute("sed -i 's/cycle=.*/cycle=" .. cycle .. "/' /etc/fan_config")
        
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "PID parameters updated"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid PID parameters"}')
    end
end
EOF

# 创建LuCI视图模板（优化图标显示）
mkdir -p /usr/lib/lua/luci/view
echo "创建LuCI视图模板..."
cat << 'EOF' > /usr/lib/lua/luci/view/sensors_monitor.htm
<%+header%>

<style>
/* 简洁白色卡片设计 */
.sensors-container {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 20px;
    padding: 15px;
}

.sensor-card {
    background: #ffffff;
    border-radius: 10px;
    padding: 20px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
    color: #333;
    border: 1px solid #eaeaea;
    position: relative;
    overflow: hidden;
}

.card-header {
    display: flex;
    align-items: center;
    margin-bottom: 15px;
    border-bottom: 1px solid #f0f0f0;
    padding-bottom: 12px;
    position: relative;
    z-index: 2;
}

.card-icon {
    font-size: 24px;
    margin-right: 12px;
    width: 44px;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #f8f9fa;
    border-radius: 10px;
    color: #4a6cf7;
}

.card-title {
    font-size: 16px;
    font-weight: 600;
    color: #555;
}

.card-value-container {
    position: relative;
    height: 100px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.card-value {
    font-size: 32px;
    font-weight: 700;
    text-align: center;
    margin: 15px 0;
    font-family: 'Courier New', monospace;
    position: relative;
    z-index: 2;
}

.card-unit {
    font-size: 16px;
    font-weight: 400;
    color: #777;
}

/* 温度颜色指示 */
.temp-low { color: #3498db; }
.temp-medium { color: #f39c12; }
.temp-high { color: #e74c3c; }

/* 风扇卡片特殊样式 */
.fan-card {
    grid-column: 1 / -1;
    background: #f8f9ff;
    border-top: 3px solid #4a6cf7;
}

.fan-card .card-icon {
    background: #eef2ff;
    color: #4a6cf7;
}

.fan-value {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-direction: column;
}

.refresh-info {
    text-align: center;
    padding: 15px;
    color: #777;
    font-size: 14px;
    background: #f9f9f9;
    border-radius: 8px;
    margin: 0 15px;
    border: 1px solid #eee;
}

.status-indicator {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 8px;
    background-color: #2ecc71;
}

/* 风扇控制滑块样式 */
.fan-control-container {
    width: 100%;
    padding: 10px 0;
    margin-top: 15px;
    position: relative;
    z-index: 2;
}

.fan-slider-container {
    display: flex;
    align-items: center;
    gap: 15px;
    margin-bottom: 15px;
}

.fan-slider {
    flex-grow: 1;
    height: 30px;
    -webkit-appearance: none;
    appearance: none;
    background: #e0e0e0;
    border-radius: 15px;
    outline: none;
}

.fan-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 30px;
    height: 30px;
    border-radius: 50%;
    background: #4a6cf7;
    cursor: pointer;
    box-shadow: 0 2px 6px rgba(0,0,0,0.2);
}

.fan-slider::-moz-range-thumb {
    width: 30px;
    height: 30px;
    border-radius: 50%;
    background: #4a6cf7;
    cursor: pointer;
    border: none;
    box-shadow: 0 2px 6px rgba(0,0,0,0.2);
}

.fan-slider-value {
    min-width: 40px;
    text-align: center;
    font-weight: bold;
    font-size: 16px;
    color: #4a6cf7;
}

/* 温控设置样式 */
.temp-control-container {
    display: flex;
    flex-wrap: wrap;
    gap: 15px;
    margin-top: 20px;
    background: #f0f5ff;
    padding: 15px;
    border-radius: 8px;
}

.temp-control-item {
    flex: 1;
    min-width: 200px;
}

.temp-control-label {
    display: block;
    margin-bottom: 8px;
    font-weight: 500;
    color: #555;
}

.temp-input {
    width: 100%;
    padding: 10px;
    border: 1px solid #ddd;
    border-radius: 6px;
    font-size: 16px;
}

.temp-set-btn {
    background: #4a6cf7;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 6px;
    cursor: pointer;
    font-weight: 500;
    transition: background 0.3s;
}

.temp-set-btn:hover {
    background: #3a5ad8;
}

.mode-switch {
    display: flex;
    gap: 10px;
    margin-top: 10px;
}

.mode-btn {
    flex: 1;
    padding: 10px;
    border: 1px solid #ddd;
    border-radius: 6px;
    background: #f8f9fa;
    text-align: center;
    cursor: pointer;
    transition: all 0.3s;
}

.mode-btn.active {
    background: #4a6cf7;
    color: white;
    border-color: #4a6cf7;
}

/* 最高温度卡片样式 */
.max-temp-card {
    grid-column: 1 / -1;
    background: #fff8f0;
    border-top: 3px solid #ff9800;
}

.max-temp-card .card-icon {
    background: #fff4e6;
    color: #ff9800;
}

/* PID控制面板样式 */
.pid-panel {
    margin-top: 20px;
    background: #f8f9ff;
    border-radius: 8px;
    padding: 15px;
    border: 1px solid #e0e0ff;
}

.pid-toggle {
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    padding: 10px;
    background: #eef2ff;
    border-radius: 6px;
}

.pid-toggle:hover {
    background: #e0e8ff;
}

.pid-title {
    font-weight: 600;
    color: #4a6cf7;
}

.pid-content {
    padding: 15px;
    display: none; /* 默认折叠 */
}

.pid-content.active {
    display: block;
}

.pid-controls {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 15px;
    margin-top: 10px;
}

.pid-control {
    display: flex;
    flex-direction: column;
}

.pid-label {
    margin-bottom: 5px;
    font-weight: 500;
    color: #555;
}

.pid-input {
    padding: 10px;
    border: 1px solid #ddd;
    border-radius: 6px;
    font-size: 16px;
}

.pid-set-btn {
    background: #4a6cf7;
    color: white;
    border: none;
    padding: 10px;
    border-radius: 6px;
    cursor: pointer;
    font-weight: 500;
    transition: background 0.3s;
    margin-top: 20px;
    width: 100%;
}

.pid-set-btn:hover {
    background: #3a5ad8;
}

/* 响应式设计 */
@media (max-width: 768px) {
    .sensors-container {
        grid-template-columns: 1fr;
    }
    
    .temp-control-container {
        flex-direction: column;
    }
    
    .pid-controls {
        grid-template-columns: 1fr;
    }
}

/* 版本信息 */
.version-info {
    position: fixed;
    bottom: 10px;
    right: 10px;
    font-size: 12px;
    color: #999;
    background: rgba(255,255,255,0.8);
    padding: 2px 5px;
    border-radius: 3px;
}

/* 曲线图背景样式 */
.chart-bg {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    z-index: 1;
    opacity: 0.5;
}
</style>

<div class="cbi-map">
    <h2 name="content"><%:硬件状态监控 V1.06%></h2>
    <div class="cbi-map-descr"><%:实时设备传感器数据 - 每秒自动刷新%></div>
    
    <div class="sensors-container" id="sensors-container">
        <!-- 卡片将由JavaScript动态生成 -->
        <div class="sensor-card">
            <div class="card-header">
                <div class="card-icon">🌡️</div>
                <div class="card-title">正在加载数据...</div>
            </div>
            <div class="card-value-container">
                <canvas class="chart-bg" id="chart-bg-placeholder"></canvas>
                <div class="card-value">--</div>
            </div>
        </div>
    </div>
    
    <div class="refresh-info">
        <span id="refresh-status">
            <span class="status-indicator"></span>
            <span>实时更新中 - 最后刷新: <span id="last-update">--:--:--</span></span>
        </span>
    </div>
</div>

<div class="version-info">Powered by UnderTheSun</div>

<script>
// 传感器配置（优化图标显示）
const sensors = [
    { id: "cpu_temp", name: "CPU温度", unit: "℃", icon: "🔥", type: "temp" },
    { id: "wifi5_temp", name: "5GHz WiFi", unit: "℃", icon: "📶", type: "temp" },
    { id: "wifi2_temp", name: "2.4GHz WiFi", unit: "℃", icon: "📡", type: "temp" },
    { id: "ssd_temp", name: "SSD温度", unit: "℃", icon: "💽", type: "temp" },
    { id: "modem_temp", name: "5G模组温度", unit: "℃", icon: "📶", type: "temp" },
    { id: "max_temp", name: "最高温度", unit: "℃", icon: "📈", type: "temp", class: "max-temp-card" },
    { id: "fan_percent", name: "风扇转速", unit: "%", icon: "🌀", type: "fan", class: "fan-card" }
];

// 历史数据存储
const historyData = {};
sensors.forEach(sensor => {
    historyData[sensor.id] = [];
});

// DOM元素
const container = document.getElementById('sensors-container');
const lastUpdateEl = document.getElementById('last-update');

// 初始化卡片
function initCards() {
    container.innerHTML = '';
    
    sensors.forEach(sensor => {
        const card = document.createElement('div');
        card.className = `sensor-card ${sensor.class || ''}`;
        card.id = `card-${sensor.id}`;
        
        if (sensor.type === 'fan') {
            // 风扇卡片特殊布局
            card.innerHTML = `
                <div class="card-header">
                    <div class="card-icon">${sensor.icon}</div>
                    <div class="card-title">${sensor.name}</div>
                </div>
                <div class="card-value-container">
                    <canvas class="chart-bg" id="chart-${sensor.id}"></canvas>
                    <div class="card-value">--</div>
                </div>
                
                <div class="fan-control-container">
                    <div class="fan-slider-container">
                        <span>手动转速:</span>
                        <input type="range" min="0" max="100" value="0" class="fan-slider" id="fan-slider">
                        <span class="fan-slider-value" id="fan-slider-value">0%</span>
                    </div>
                    
                    <div class="temp-control-container">
                        <div class="temp-control-item">
                            <label class="temp-control-label">目标温度 (℃)</label>
                            <input type="number" min="40" max="80" value="55" class="temp-input" id="target-temp-input">
                            <button class="temp-set-btn" onclick="setTargetTemp()">设置</button>
                        </div>
                        
                        <div class="temp-control-item">
                            <label class="temp-control-label">工作模式</label>
                            <div class="mode-switch">
                                <div class="mode-btn" data-mode="auto" onclick="setMode('auto')">自动温控</div>
                                <div class="mode-btn" data-mode="manual" onclick="setMode('manual')">手动控制</div>
                            </div>
                        </div>
                    </div>
                    
                    <div id="fan-status">当前模式: <span id="current-mode">--</span> | 目标温度: <span id="current-temp">--</span>℃</div>
                    
                    <!-- PID控制面板 -->
                    <div class="pid-panel">
                        <div class="pid-toggle" onclick="togglePidPanel()">
                            <span class="pid-title">PID参数设置</span>
                            <span id="pid-toggle-icon">▼</span>
                        </div>
                        <div class="pid-content" id="pid-content">
                            <div class="pid-controls">
                                <div class="pid-control">
                                    <label class="pid-label">比例系数 (Kp)</label>
                                    <input type="number" step="0.1" min="0.1" max="20" class="pid-input" id="kp-input">
                                </div>
                                
                                <div class="pid-control">
                                    <label class="pid-label">积分系数 (Ki)</label>
                                    <input type="number" step="0.01" min="0.01" max="5" class="pid-input" id="ki-input">
                                </div>
                                
                                <div class="pid-control">
                                    <label class="pid-label">微分系数 (Kd)</label>
                                    <input type="number" step="0.1" min="0" max="10" class="pid-input" id="kd-input">
                                </div>
                                
                                <div class="pid-control">
                                    <label class="pid-label">控制周期 (秒)</label>
                                    <input type="number" min="1" max="10" class="pid-input" id="cycle-input">
                                </div>
                            </div>
                            
                            <button class="pid-set-btn" onclick="setPidParams()">保存PID设置</button>
                        </div>
                    </div>
                </div>
            `;
        } else {
            // 温度卡片布局
            card.innerHTML = `
                <div class="card-header">
                    <div class="card-icon">${sensor.icon}</div>
                    <div class="card-title">${sensor.name}</div>
                </div>
                <div class="card-value-container">
                    <canvas class="chart-bg" id="chart-${sensor.id}"></canvas>
                    <div class="card-value">--</div>
                </div>
            `;
        }
        
        container.appendChild(card);
    });
    
    // 初始化风扇滑块事件
    const fanSlider = document.getElementById('fan-slider');
    if (fanSlider) {
        fanSlider.addEventListener('input', function() {
            const value = this.value;
            document.getElementById('fan-slider-value').textContent = value + '%';
        });
        
        fanSlider.addEventListener('change', function() {
            setFanSpeed(this.value);
        });
    }
}

// 绘制曲线背景
function drawChart(canvasId, values, maxValue = 80, minValue = 20) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    
    const ctx = canvas.getContext('2d');
    const width = canvas.width;
    const height = canvas.height;
    
    // 清除画布
    ctx.clearRect(0, 0, width, height);
    
    // 设置线条样式
    ctx.strokeStyle = '#4a6cf7';
    ctx.lineWidth = 2;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    
    // 开始绘制路径
    ctx.beginPath();
    
    // 计算每个点的位置
    const pointCount = values.length;
    const stepX = width / (pointCount - 1);
    
    // 绘制曲线
    for (let i = 0; i < pointCount; i++) {
        const value = values[i] === 'N/A' ? minValue : Math.min(Math.max(values[i], minValue), maxValue);
        const x = i * stepX;
        const y = height - ((value - minValue) / (maxValue - minValue)) * height;
        
        if (i === 0) {
            ctx.moveTo(x, y);
        } else {
            // 使用二次贝塞尔曲线平滑
            const prevX = (i - 1) * stepX;
            const prevY = height - ((values[i-1] - minValue) / (maxValue - minValue)) * height;
            
            const cpx = (prevX + x) / 2;
            ctx.quadraticCurveTo(cpx, prevY, x, y);
        }
    }
    
    // 描边路径
    ctx.stroke();
}

// 设置风扇速度
function setFanSpeed(percent) {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/setfan") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    
    xhr.onload = function() {
        if (xhr.status === 200) {
            try {
                const response = JSON.parse(xhr.responseText);
                if (response.result === 'success') {
                    console.log('Fan speed set:', response.message);
                } else {
                    console.error('Error setting fan speed:', response.message);
                }
            } catch (e) {
                console.error('Error parsing response:', e);
            }
        } else {
            console.error('Request failed with status:', xhr.status);
        }
    };
    
    xhr.onerror = function() {
        console.error('Request failed');
    };
    
    xhr.send('fan_percent=' + encodeURIComponent(percent));
}

// 设置目标温度
function setTargetTemp() {
    const tempInput = document.getElementById('target-temp-input');
    const tempValue = tempInput.value;
    
    if (!tempValue || tempValue < 40 || tempValue > 80) {
        alert('请输入有效的温度值 (40-80℃)');
        return;
    }
    
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/settemp") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    
    xhr.onload = function() {
        if (xhr.status === 200) {
            try {
                const response = JSON.parse(xhr.responseText);
                if (response.result === 'success') {
                    console.log('Target temperature set:', response.message);
                    document.getElementById('current-temp').textContent = tempValue;
                } else {
                    console.error('Error setting temperature:', response.message);
                }
            } catch (e) {
                console.error('Error parsing response:', e);
            }
        } else {
            console.error('Request failed with status:', xhr.status);
        }
    };
    
    xhr.send('target_temp=' + encodeURIComponent(tempValue));
}

// 设置工作模式
function setMode(mode) {
    // 更新UI
    document.querySelectorAll('.mode-btn').forEach(btn => {
        if (btn.dataset.mode === mode) {
            btn.classList.add('active');
        } else {
            btn.classList.remove('active');
        }
    });
    
    // 获取当前风扇速度用于手动模式
    const fanSpeed = mode === 'manual' ? document.getElementById('fan-slider').value : '0';
    
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/setmode") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    
    xhr.onload = function() {
        if (xhr.status === 200) {
            try {
                const response = JSON.parse(xhr.responseText);
                if (response.result === 'success') {
                    console.log('Mode set:', response.message);
                    document.getElementById('current-mode').textContent = 
                        mode === 'auto' ? '自动温控' : '手动控制';
                } else {
                    console.error('Error setting mode:', response.message);
                }
            } catch (e) {
                console.error('Error parsing response:', e);
            }
        } else {
            console.error('Request failed with status:', xhr.status);
        }
    };
    
    xhr.send('mode=' + encodeURIComponent(mode) + '&fan_percent=' + encodeURIComponent(fanSpeed));
}

// 切换PID面板显示状态
function togglePidPanel() {
    const pidContent = document.getElementById('pid-content');
    const pidIcon = document.getElementById('pid-toggle-icon');
    
    if (pidContent.classList.contains('active')) {
        pidContent.classList.remove('active');
        pidIcon.textContent = '▼';
    } else {
        pidContent.classList.add('active');
        pidIcon.textContent = '▲';
    }
}

// 设置PID参数
function setPidParams() {
    const kpInput = document.getElementById('kp-input');
    const kiInput = document.getElementById('ki-input');
    const kdInput = document.getElementById('kd-input');
    const cycleInput = document.getElementById('cycle-input');
    
    const kp = kpInput.value;
    const ki = kiInput.value;
    const kd = kdInput.value;
    const cycle = cycleInput.value;
    
    // 验证输入
    if (!kp || !ki || !kd || !cycle) {
        alert('请填写所有PID参数');
        return;
    }
    
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/setpid") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    
    xhr.onload = function() {
        if (xhr.status === 200) {
            try {
                const response = JSON.parse(xhr.responseText);
                if (response.result === 'success') {
                    alert('PID参数更新成功！');
                } else {
                    console.error('Error setting PID:', response.message);
                    alert('设置PID参数时出错: ' + response.message);
                }
            } catch (e) {
                console.error('Error parsing response:', e);
                alert('解析响应时出错');
            }
        } else {
            console.error('Request failed with status:', xhr.status);
            alert('请求失败，状态码: ' + xhr.status);
        }
    };
    
    xhr.onerror = function() {
        console.error('Request failed');
        alert('请求失败');
    };
    
    xhr.send('kp=' + encodeURIComponent(kp) + 
             '&ki=' + encodeURIComponent(ki) + 
             '&kd=' + encodeURIComponent(kd) + 
             '&cycle=' + encodeURIComponent(cycle));
}

// 更新卡片数据
function updateCards(data) {
    sensors.forEach(sensor => {
        const value = data[sensor.id] || 'N/A';
        const card = document.getElementById(`card-${sensor.id}`);
        
        if (card) {
            const valueEl = card.querySelector('.card-value');
            
            // 更新值
            if (value !== 'N/A') {
                // 特殊处理风扇卡片
                if (sensor.type === 'fan') {
                    const fanPercent = parseInt(value);
                    valueEl.innerHTML = `${fanPercent}<span class="card-unit">%</span>`;
                    
                    // 更新滑块值（仅当不在手动模式）
                    if (data.fan_mode !== 'manual') {
                        const slider = document.getElementById('fan-slider');
                        const sliderValue = document.getElementById('fan-slider-value');
                        if (slider && sliderValue) {
                            slider.value = fanPercent;
                            sliderValue.textContent = fanPercent + '%';
                        }
                    }
                    
                    // 更新状态信息
                    document.getElementById('current-mode').textContent = 
                        data.fan_mode === 'auto' ? '自动温控' : '手动控制';
                    document.getElementById('current-temp').textContent = 
                        data.fan_target_temp || '55';
                    
                    // 设置活动模式按钮
                    document.querySelectorAll('.mode-btn').forEach(btn => {
                        if (btn.dataset.mode === data.fan_mode) {
                            btn.classList.add('active');
                        } else {
                            btn.classList.remove('active');
                        }
                    });
                    
                    // 更新目标温度输入框（仅当输入框没有焦点）
                    const tempInput = document.getElementById('target-temp-input');
                    if (tempInput && document.activeElement !== tempInput) {
                        tempInput.value = data.fan_target_temp || '55';
                    }
                    
                    // 更新PID参数输入框（仅当没有焦点）
                    const kpInput = document.getElementById('kp-input');
                    const kiInput = document.getElementById('ki-input');
                    const kdInput = document.getElementById('kd-input');
                    const cycleInput = document.getElementById('cycle-input');
                    
                    if (kpInput && document.activeElement !== kpInput) kpInput.value = data.kp || '5.0';
                    if (kiInput && document.activeElement !== kiInput) kiInput.value = data.ki || '0.1';
                    if (kdInput && document.activeElement !== kdInput) kdInput.value = data.kd || '1.0';
                    if (cycleInput && document.activeElement !== cycleInput) cycleInput.value = data.cycle || '10';
                } else {
                    valueEl.innerHTML = `${value}<span class="card-unit">${sensor.unit}</span>`;
                    
                    // 根据温度设置颜色
                    if (sensor.type === 'temp') {
                        const temp = parseInt(value);
                        if (!isNaN(temp)) {
                            valueEl.className = 'card-value ' + (
                                temp < 50 ? 'temp-low' : 
                                temp < 70 ? 'temp-medium' : 'temp-high'
                            );
                        }
                    }
                }
                
                // 更新历史数据
                if (historyData[sensor.id].length >= 60) {
                    historyData[sensor.id].shift();
                }
                historyData[sensor.id].push(value === 'N/A' ? 0 : parseInt(value));
                
                // 绘制曲线图
                drawChart(`chart-${sensor.id}`, historyData[sensor.id], 
                         sensor.id === 'fan_percent' ? 100 : 80, 
                         sensor.id === 'fan_percent' ? 0 : 20);
            } else {
                valueEl.innerHTML = 'N/A';
                valueEl.className = 'card-value';
            }
        }
    });
    
    // 更新最后刷新时间
    const now = new Date();
    lastUpdateEl.textContent = now.toTimeString().substring(0, 8);
}

// 获取传感器数据
function fetchSensorData() {
    const xhr = new XMLHttpRequest();
    xhr.open('GET', '<%= url("admin/status/sensors/data") %>');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    
    xhr.onload = function() {
        if (xhr.status === 200) {
            try {
                const data = JSON.parse(xhr.responseText);
                updateCards(data);
            } catch (e) {
                console.error('Error parsing sensor data:', e);
            }
        }
    };
    
    xhr.send();
}

// 初始化
document.addEventListener('DOMContentLoaded', function() {
    initCards();
    fetchSensorData(); // 初始加载
    
    // 设置每秒刷新
    setInterval(fetchSensorData, 1000);
});
</script>

<%+footer%>
EOF

# 创建风扇配置文件
echo "创建风扇配置文件..."
cat << 'EOF' > /etc/fan_config
# 风扇控制配置
mode=auto
target_temp=55
min_speed=20
max_speed=100

# PID参数设置
kp=5.0
ki=0.1
kd=1.0
cycle=10
EOF

# 创建开机启动服务
echo "创建开机启动服务..."
cat << 'EOF' > /etc/init.d/fancontrol
#!/bin/sh /etc/rc.common
# Copyright (C) 2006-2023 OpenWrt.org

START=99
STOP=10

start() {
    echo "Starting fan control service"
    # 确保获取风扇控制权
    if [ -f /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 ]; then
        chmod 666 /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1
    fi
    /usr/bin/fan_control >/tmp/fan_control.log 2>&1 &
}

stop() {
    echo "Stopping fan control service"
    pkill -f "/usr/bin/fan_control"
}

restart() {
    stop
    sleep 1
    start
}
EOF

# 设置权限
chmod +x /etc/init.d/fancontrol
chmod +x /usr/bin/fan_control
chmod +x /usr/bin/set_fan_speed
chmod +x /usr/bin/sensors_monitor

# 启用并启动服务
/etc/init.d/fancontrol enable
/etc/init.d/fancontrol start

# 安装bc命令用于浮点计算
if ! command -v bc >/dev/null; then
    echo "安装bc命令用于PID计算..."
    opkg update
    opkg install bc
fi

# 重启服务
/etc/init.d/uhttpd restart

echo "=============================================="
echo " 温度监控和风扇控制已成功安装 V1.06"
echo "----------------------------------------------"
echo " 主要改进："
echo "  - 修复5G模组温度提取问题"
echo "  - 优化图标显示（SSD使用💽，5G使用📶）"
echo "  - 添加清理旧文件功能防止冲突"
echo "  - 增强错误处理和日志输出"
echo "----------------------------------------------"
echo " PID温控参数范围："
echo "  Kp: 0.1-20.0 (推荐5.0)"
echo "  Ki: 0.01-5.0 (推荐0.1)"
echo "  Kd: 0-10.0 (推荐1.0)"
echo "  周期: 1-10秒 (推荐10)"
echo "----------------------------------------------"
echo " 访问路径: LuCI -> 状态 -> 硬件监控"
echo "=============================================="
echo " Powered by UnderTheSun"

echo "Write all buffered blocks to disk..."
sync
echo "Done!"
