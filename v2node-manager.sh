#!/usr/bin/env bash
set -e
set -u
# 尝试启用 pipefail（如果支持）
if (set -o pipefail 2>/dev/null); then
  set -o pipefail
fi

# V2Node 配置文件路径
CONFIG_FILE="/etc/v2node/config.json"

# 颜色样式
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
GRAY='\033[90m'
BOLD='\033[1m'
RESET='\033[0m'

# 检查 jq 是否安装
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: jq 未安装${RESET}"
    echo -e "${YELLOW}正在安装 jq...${RESET}"
    if command -v apt-get &> /dev/null; then
      sudo apt-get update && sudo apt-get install -y jq
    elif command -v yum &> /dev/null; then
      sudo yum install -y jq
    else
      echo -e "${RED}无法自动安装 jq，请手动安装${RESET}"
      exit 1
    fi
  fi
}

# 检查配置文件是否存在
check_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}配置文件不存在: $CONFIG_FILE${RESET}"
    echo -e "${YELLOW}正在创建默认配置文件...${RESET}"
    sudo mkdir -p "$(dirname "$CONFIG_FILE")"
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
{
    "Log": {
        "Level": "warning",
        "Output": "",
        "Access": "none"
    },
    "Nodes": []
}
EOF
    echo -e "${GREEN}已创建默认配置文件${RESET}"
  fi
}

# 重启 v2node 服务
restart_v2node() {
  echo ""
  echo -e "${YELLOW}正在重启 v2node 服务...${RESET}"
  
  # 尝试使用 systemctl
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --type=service --all | grep -q "v2node"; then
      if sudo systemctl restart v2node 2>/dev/null; then
        echo -e "${GREEN}v2node 服务已重启${RESET}"
        return 0
      fi
    fi
  fi
  
  # 尝试使用 service 命令
  if command -v service >/dev/null 2>&1; then
    if sudo service v2node restart 2>/dev/null; then
      echo -e "${GREEN}v2node 服务已重启${RESET}"
      return 0
    fi
  fi
  
  # 如果都失败，提示手动重启
  echo -e "${YELLOW}无法自动重启 v2node 服务，请手动重启${RESET}"
  echo -e "${GRAY}可以尝试: systemctl restart v2node 或 service v2node restart${RESET}"
}

# 列出所有节点
list_nodes() {
  echo -e "${BOLD}${CYAN}当前节点列表:${RESET}"
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}暂无节点${RESET}"
    return
  fi
  
  echo -e "${GRAY}共 $node_count 个节点${RESET}"
  echo ""
  
  # 使用 jq 格式化输出
  sudo jq -r '.Nodes | to_entries | .[] | 
    "节点 #\(.key + 1)\n" +
    "  NodeID: \(.value.NodeID)\n" +
    "  ApiHost: \(.value.ApiHost)\n" +
    "  ApiKey: \(.value.ApiKey)\n" +
    "  Timeout: \(.value.Timeout)\n"' "$CONFIG_FILE"
}

# 删除节点
delete_node() {
  list_nodes
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}没有可删除的节点${RESET}"
    return
  fi
  
  echo -en "${BOLD}请输入要删除的节点编号或 NodeID (1-$node_count 或 NodeID，支持单个、范围或逗号分隔，如 1,3,5 或 1-5 或 96-98): ${RESET}"
  read -r input
  
  if [[ -z "$input" ]]; then
    echo -e "${RED}取消操作${RESET}"
    return
  fi
  
  # 获取所有 NodeID 列表（用于通过 NodeID 删除）
  local nodeid_list=()
  local nodeid_to_index=()
  local index=0
  while IFS= read -r nodeid; do
    nodeid_list+=("$nodeid")
    nodeid_to_index["$nodeid"]=$index
    index=$((index + 1))
  done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
  
  # 解析输入（支持逗号分隔的多个编号和范围）
  local all_numbers=()
  IFS=',' read -ra parts <<< "$input"
  
  # 处理每个部分（可能是单个数字或范围）
  for part in "${parts[@]}"; do
    part=$(echo "$part" | tr -d ' ')
    if [[ -z "$part" ]]; then
      continue
    fi
    
    # 尝试解析为范围或单个数字
    # 先检查是否是纯数字（单个）
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      all_numbers+=("$part")
    # 再检查是否是范围格式
    elif [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start=$(echo "$part" | cut -d'-' -f1)
      local end=$(echo "$part" | cut -d'-' -f2)
      
      if [[ "$start" -le "$end" ]]; then
        for ((i=start; i<=end; i++)); do
          all_numbers+=("$i")
        done
      else
        echo -e "${RED}范围错误: 起始值必须小于等于结束值 ($part)${RESET}"
        return
      fi
    else
      echo -e "${RED}无效的输入格式: $part (请输入数字或范围，如 96 或 96-98)${RESET}"
      return
    fi
  done
  
  if [[ ${#all_numbers[@]} -eq 0 ]]; then
    echo -e "${RED}没有有效的输入${RESET}"
    return
  fi
  
  # 判断是节点编号还是 NodeID，并转换为数组索引
  local delete_indices=()
  declare -A seen
  
  for num in "${all_numbers[@]}"; do
    # 首先尝试作为节点编号（1 到 node_count）
    if [[ "$num" -ge 1 ]] && [[ "$num" -le "$node_count" ]]; then
      local idx=$((num - 1))
      if [[ -z "${seen[$idx]:-}" ]]; then
        seen[$idx]=1
        delete_indices+=($idx)
      fi
    else
      # 如果不是节点编号，尝试作为 NodeID
      local found=false
      for i in "${!nodeid_list[@]}"; do
        if [[ "${nodeid_list[$i]}" == "$num" ]]; then
          if [[ -z "${seen[$i]:-}" ]]; then
            seen[$i]=1
            delete_indices+=($i)
            found=true
          fi
          break
        fi
      done
      
      if [[ "$found" == "false" ]]; then
        echo -e "${YELLOW}警告: 未找到 NodeID $num，跳过${RESET}"
      fi
    fi
  done
  
  if [[ ${#delete_indices[@]} -eq 0 ]]; then
    echo -e "${RED}没有找到要删除的节点${RESET}"
    return
  fi
  
  # 排序（从大到小，避免删除后索引变化）
  IFS=$'\n' delete_indices=($(printf '%s\n' "${delete_indices[@]}" | sort -rn))
  
  # 删除节点（从后往前删除，避免索引变化）
  local temp_file=$(mktemp)
  sudo cp "$CONFIG_FILE" "$temp_file"
  
  for idx in "${delete_indices[@]}"; do
    sudo jq "del(.Nodes[$idx])" "$temp_file" > "${temp_file}.new"
    mv "${temp_file}.new" "$temp_file"
  done
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 644 "$CONFIG_FILE"
  
  echo -e "${GREEN}已删除 ${#delete_indices[@]} 个节点${RESET}"
  
  # 重启 v2node 服务
  restart_v2node
}

# 解析范围输入（如 1-5）
parse_range() {
  local input="$1"
  local result=()
  
  if [[ "$input" =~ ^[0-9]+-[0-9]+$ ]]; then
    local start=$(echo "$input" | cut -d'-' -f1)
    local end=$(echo "$input" | cut -d'-' -f2)
    
    if [[ "$start" -le "$end" ]]; then
      for ((i=start; i<=end; i++)); do
        result+=($i)
      done
    else
      echo -e "${RED}范围错误: 起始值必须小于等于结束值${RESET}" >&2
      return 1
    fi
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    result+=($input)
  else
    echo -e "${RED}格式错误: 请输入数字或范围（如 1-5）${RESET}" >&2
    return 1
  fi
  
  echo "${result[@]}"
}

# 添加节点
add_node() {
  echo -e "${BOLD}${CYAN}添加新节点${RESET}"
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  local api_host=""
  local api_key=""
  local timeout=15
  
  # 如果有现有节点，询问是否沿用
  if [[ "$node_count" -gt 0 ]]; then
    echo -e "${BOLD}是否沿用已有节点的 ApiHost 和 ApiKey？${RESET}"
    echo -e "  ${YELLOW}1)${RESET} 是，选择已有节点"
    echo -e "  ${YELLOW}2)${RESET} 否，手动输入"
    echo -en "${BOLD}你的选择 (默认: 2): ${RESET}"
    read -r use_existing
    
    if [[ "$use_existing" == "1" ]]; then
      # 列出所有节点供选择
      echo ""
      echo -e "${BOLD}${CYAN}请选择要沿用的节点:${RESET}"
      echo ""
      
      # 显示节点列表
      local index=0
      while IFS=$'\t' read -r nodeid host key; do
        index=$((index + 1))
        echo -e "  ${YELLOW}$index)${RESET} NodeID: $nodeid, ApiHost: $host"
      done < <(sudo jq -r '.Nodes[] | "\(.NodeID)\t\(.ApiHost)\t\(.ApiKey)"' "$CONFIG_FILE")
      
      echo ""
      echo -en "${BOLD}请输入节点编号 (1-$node_count): ${RESET}"
      read -r selected_index
      
      if [[ -z "$selected_index" ]] || ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [[ "$selected_index" -lt 1 ]] || [[ "$selected_index" -gt "$node_count" ]]; then
        echo -e "${RED}无效的节点编号，取消操作${RESET}"
        return
      fi
      
      local array_index=$((selected_index - 1))
      api_host=$(sudo jq -r ".Nodes[$array_index].ApiHost" "$CONFIG_FILE")
      api_key=$(sudo jq -r ".Nodes[$array_index].ApiKey" "$CONFIG_FILE")
      timeout=$(sudo jq -r ".Nodes[$array_index].Timeout" "$CONFIG_FILE")
      
      echo ""
      echo -e "${GREEN}已选择节点配置:${RESET}"
      echo -e "  ${GRAY}ApiHost: $api_host${RESET}"
      echo -e "  ${GRAY}ApiKey: $api_key${RESET}"
      echo -e "  ${GRAY}Timeout: $timeout${RESET}"
      echo ""
    else
      # 手动输入配置
      echo ""
      echo -en "${BOLD}API Host: ${RESET}"
      read -r api_host
      if [[ -z "$api_host" ]]; then
        echo -e "${RED}API Host 不能为空${RESET}"
        return
      fi
      
      echo -en "${BOLD}API Key: ${RESET}"
      read -r api_key
      if [[ -z "$api_key" ]]; then
        echo -e "${RED}API Key 不能为空${RESET}"
        return
      fi
      
      echo -en "${BOLD}Timeout (默认: 15): ${RESET}"
      read -r timeout_input
      timeout=${timeout_input:-15}
    fi
  else
    # 没有现有节点，必须手动输入
    echo -en "${BOLD}API Host: ${RESET}"
    read -r api_host
    if [[ -z "$api_host" ]]; then
      echo -e "${RED}API Host 不能为空${RESET}"
      return
    fi
    
    echo -en "${BOLD}API Key: ${RESET}"
    read -r api_key
    if [[ -z "$api_key" ]]; then
      echo -e "${RED}API Key 不能为空${RESET}"
      return
    fi
    
    echo -en "${BOLD}Timeout (默认: 15): ${RESET}"
    read -r timeout_input
    timeout=${timeout_input:-15}
  fi
  
  # 输入 NodeID
  echo ""
  echo -en "${BOLD}NodeID (单个数字，如 95，或范围，如 1-5): ${RESET}"
  read -r nodeid_input
  
  if [[ -z "$nodeid_input" ]]; then
    echo -e "${RED}取消操作${RESET}"
    return
  fi
  
  # 解析 NodeID（支持单个或范围）
  local nodeids
  if ! nodeids=$(parse_range "$nodeid_input"); then
    return
  fi
  
  # 检查 NodeID 是否已存在
  local existing_nodeids=()
  if [[ "$node_count" -gt 0 ]]; then
    while IFS= read -r nodeid; do
      existing_nodeids+=("$nodeid")
    done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
  fi
  
  local nodes_to_add=()
  for nodeid in $nodeids; do
    # 检查是否已存在
    local exists=false
    for existing in "${existing_nodeids[@]}"; do
      if [[ "$nodeid" == "$existing" ]]; then
        echo -e "${YELLOW}警告: NodeID $nodeid 已存在，将跳过${RESET}"
        exists=true
        break
      fi
    done
    
    if [[ "$exists" == "false" ]]; then
      nodes_to_add+=("$nodeid")
    fi
  done
  
  if [[ ${#nodes_to_add[@]} -eq 0 ]]; then
    echo -e "${RED}没有可添加的节点（所有 NodeID 都已存在）${RESET}"
    return
  fi
  
  # 添加节点
  local temp_file=$(mktemp)
  sudo cp "$CONFIG_FILE" "$temp_file"
  
  for nodeid in "${nodes_to_add[@]}"; do
    local new_node=$(jq -n \
      --arg api_host "$api_host" \
      --argjson nodeid "$nodeid" \
      --arg api_key "$api_key" \
      --argjson timeout "$timeout" \
      '{
        "ApiHost": $api_host,
        "NodeID": $nodeid,
        "ApiKey": $api_key,
        "Timeout": $timeout
      }')
    
    sudo jq ".Nodes += [$new_node]" "$temp_file" > "${temp_file}.new"
    mv "${temp_file}.new" "$temp_file"
  done
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 644 "$CONFIG_FILE"
  
  echo ""
  echo -e "${GREEN}已添加 ${#nodes_to_add[@]} 个节点${RESET}"
  echo -e "${GRAY}NodeID: ${nodes_to_add[*]}${RESET}"
  echo -e "${GRAY}ApiHost: $api_host${RESET}"
  
  # 重启 v2node 服务
  restart_v2node
}

# 编辑节点
edit_node() {
  list_nodes
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}没有可编辑的节点${RESET}"
    return
  fi
  
  echo -en "${BOLD}请输入要编辑的节点编号 (1-$node_count): ${RESET}"
  read -r node_index
  
  if [[ -z "$node_index" ]] || ! [[ "$node_index" =~ ^[0-9]+$ ]] || [[ "$node_index" -lt 1 ]] || [[ "$node_index" -gt "$node_count" ]]; then
    echo -e "${RED}无效的节点编号${RESET}"
    return
  fi
  
  local array_index=$((node_index - 1))
  
  # 获取当前值
  local current_node=$(sudo jq ".Nodes[$array_index]" "$CONFIG_FILE")
  local current_nodeid=$(echo "$current_node" | jq -r '.NodeID')
  local current_api_host=$(echo "$current_node" | jq -r '.ApiHost')
  local current_api_key=$(echo "$current_node" | jq -r '.ApiKey')
  local current_timeout=$(echo "$current_node" | jq -r '.Timeout')
  
  echo ""
  echo -e "${GRAY}当前配置:${RESET}"
  echo -e "  NodeID: $current_nodeid"
  echo -e "  ApiHost: $current_api_host"
  echo -e "  ApiKey: $current_api_key"
  echo -e "  Timeout: $current_timeout"
  echo ""
  
  # 输入新值（回车保持原值）
  echo -en "${BOLD}NodeID (默认: $current_nodeid): ${RESET}"
  read -r new_nodeid
  new_nodeid=${new_nodeid:-$current_nodeid}
  
  echo -en "${BOLD}API Host (默认: $current_api_host): ${RESET}"
  read -r new_api_host
  new_api_host=${new_api_host:-$current_api_host}
  
  echo -en "${BOLD}API Key (默认: $current_api_key): ${RESET}"
  read -r new_api_key
  new_api_key=${new_api_key:-$current_api_key}
  
  echo -en "${BOLD}Timeout (默认: $current_timeout): ${RESET}"
  read -r new_timeout
  new_timeout=${new_timeout:-$current_timeout}
  
  # 检查 NodeID 是否与其他节点冲突
  if [[ "$new_nodeid" != "$current_nodeid" ]]; then
    local existing_nodeids=()
    while IFS= read -r nodeid; do
      if [[ "$nodeid" != "$current_nodeid" ]]; then
        existing_nodeids+=("$nodeid")
      fi
    done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
    
    for existing in "${existing_nodeids[@]}"; do
      if [[ "$new_nodeid" == "$existing" ]]; then
        echo -e "${RED}错误: NodeID $new_nodeid 已被其他节点使用${RESET}"
        return
      fi
    done
  fi
  
  # 更新节点
  local temp_file=$(mktemp)
  sudo jq \
    --argjson nodeid "$new_nodeid" \
    --arg api_host "$new_api_host" \
    --arg api_key "$new_api_key" \
    --argjson timeout "$new_timeout" \
    ".Nodes[$array_index] = {
      \"NodeID\": \$nodeid,
      \"ApiHost\": \$api_host,
      \"ApiKey\": \$api_key,
      \"Timeout\": \$timeout
    }" "$CONFIG_FILE" > "$temp_file"
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 644 "$CONFIG_FILE"
  
  echo -e "${GREEN}节点已更新${RESET}"
  
  # 重启 v2node 服务
  restart_v2node
}

# 主菜单
function v2node_menu() {
  while true; do
    echo ""
    echo -e "${BOLD}${CYAN}V2Node 配置管理${RESET}"
    echo -e "${GRAY}配置文件: $CONFIG_FILE${RESET}"
    echo ""
    echo -e "${BOLD}请选择要执行的操作 (输入数字回车):${RESET}"
    echo -e "  ${YELLOW}1)${RESET} 列出所有节点"
    echo -e "  ${YELLOW}2)${RESET} 添加节点 (${GRAY}支持范围添加，如 1-5${RESET})"
    echo -e "  ${YELLOW}3)${RESET} 删除节点 (${GRAY}支持范围删除，如 1-5 或 96-98${RESET})"
    echo -e "  ${YELLOW}4)${RESET} 编辑节点"
    echo -e "  ${YELLOW}5)${RESET} 查看配置文件内容"
    echo -e "  ${YELLOW}0)${RESET} 返回主菜单"
    echo -en "${BOLD}你的选择:${RESET} "
    
    read -r choice
    
    case "$choice" in
      1) 
        list_nodes
        echo ""
        echo -e "${GREEN}完成。${RESET}按回车键继续..."
        read -r
        ;;
      2) 
        add_node
        echo ""
        echo -e "${GREEN}完成。${RESET}按回车键继续..."
        read -r
        ;;
      3) 
        delete_node
        echo ""
        echo -e "${GREEN}完成。${RESET}按回车键继续..."
        read -r
        ;;
      4) 
        edit_node
        echo ""
        echo -e "${GREEN}完成。${RESET}按回车键继续..."
        read -r
        ;;
      5) 
        echo ""
        echo -e "${BOLD}${CYAN}配置文件内容:${RESET}"
        sudo cat "$CONFIG_FILE" | jq .
        echo ""
        echo -e "${GREEN}完成。${RESET}按回车键继续..."
        read -r
        ;;
      0) 
        return 0
        ;;
      *) 
        echo -e "${RED}无效选项${RESET}，请重新选择"
        sleep 1
        ;;
    esac
  done
}

# 主函数
main() {
  # 显示标题
  echo -e "${BLUE}==============================================${RESET}"
  echo -e "${BOLD}${CYAN} V2Node 配置管理工具${RESET}"
  echo -e "${GRAY}配置文件: $CONFIG_FILE${RESET}"
  echo -e "${BLUE}==============================================${RESET}"
  
  check_jq
  check_config
  v2node_menu
}

# 如果直接执行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi

