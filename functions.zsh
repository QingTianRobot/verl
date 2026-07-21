#!/usr/bin/env zsh

typeset -g VERL_H200_ROOT="${${(%):-%N}:A:h}"
typeset -g VERL_H200_COMPOSE_FILE="${VERL_H200_COMPOSE_FILE:-${VERL_H200_ROOT}/docker-compose.h200.yaml}"
typeset -g VERL_H200_ENV_FILE="${VERL_H200_ENV_FILE:-${VERL_H200_ROOT}/.env.h200}"

_verl_h200_error() {
  print -u2 -r -- "[verl-h200] $*"
}

_verl_h200_require_env() {
  if [[ ! -f "${VERL_H200_ENV_FILE}" ]]; then
    _verl_h200_error "找不到 ${VERL_H200_ENV_FILE}"
    _verl_h200_error "请先运行: verl_h200_prepare"
    return 1
  fi
}

_verl_h200_env_value() {
  local key="$1"
  [[ -r "${VERL_H200_ENV_FILE}" ]] || return 1
  command awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "${VERL_H200_ENV_FILE}"
}

_verl_h200_compose() {
  _verl_h200_require_env || return 1
  command env H200_ENV_FILE="${VERL_H200_ENV_FILE}" \
    docker compose \
      --project-directory "${VERL_H200_ROOT}" \
      --env-file "${VERL_H200_ENV_FILE}" \
      -f "${VERL_H200_COMPOSE_FILE}" \
      "$@"
}

_verl_h200_service() {
  case "${1:-}" in
    head) print -r -- "ray-head" ;;
    worker) print -r -- "ray-worker" ;;
    *)
      _verl_h200_error "角色必须是 head 或 worker"
      return 1
      ;;
  esac
}

verl_h200_prepare() {
  if [[ -e "${VERL_H200_ENV_FILE}" ]]; then
    print -r -- "配置已存在: ${VERL_H200_ENV_FILE}"
  else
    command cp "${VERL_H200_ROOT}/.env.h200.example" "${VERL_H200_ENV_FILE}" || return 1
    print -r -- "已创建配置: ${VERL_H200_ENV_FILE}"
  fi
  print -r -- "请设置 RAY_HEAD_IP、当前节点 NODE_IP、GPU/CPU 数量和共享目录。"
}

verl_h200_config() {
  local role="${1:-head}"
  _verl_h200_service "${role}" >/dev/null || return 1
  _verl_h200_compose --profile "${role}" config
}

verl_h200_build() {
  local role="${1:-head}"
  _verl_h200_service "${role}" >/dev/null || return 1
  _verl_h200_compose --profile "${role}" build
}

verl_h200_pull() {
  local role="${1:-head}"
  local service="$(_verl_h200_service "${role}")" || return 1
  _verl_h200_compose --profile "${role}" pull "${service}"
}

verl_h200_head_up() {
  _verl_h200_compose --profile head up -d --no-build ray-head
}

verl_h200_worker_up() {
  _verl_h200_compose --profile worker up -d --no-build ray-worker
}

verl_h200_status() {
  _verl_h200_compose --profile head exec -T ray-head ray status
}

verl_h200_dashboard() {
  _verl_h200_require_env || return 1
  local head_ip="$(_verl_h200_env_value RAY_HEAD_IP)"
  local dashboard_port="$(_verl_h200_env_value RAY_DASHBOARD_PORT)"
  dashboard_port="${dashboard_port:-8265}"
  [[ -n "${head_ip}" ]] || {
    _verl_h200_error "RAY_HEAD_IP 尚未配置"
    return 1
  }
  print -r -- "http://${head_ip}:${dashboard_port}"
}

verl_h200_shell() {
  _verl_h200_compose --profile head exec ray-head /bin/bash
}

verl_h200_logs() {
  local role="${1:-head}"
  local service="$(_verl_h200_service "${role}")" || return 1
  _verl_h200_compose --profile "${role}" logs --tail=200 -f "${service}"
}

verl_h200_restart() {
  local role="${1:-head}"
  local service="$(_verl_h200_service "${role}")" || return 1
  _verl_h200_compose --profile "${role}" restart "${service}"
}

verl_h200_down() {
  local role="${1:-head}"
  _verl_h200_service "${role}" >/dev/null || return 1
  _verl_h200_compose --profile "${role}" down
}

verl_h200_submit() {
  (( $# > 0 )) || {
    _verl_h200_error "用法: verl_h200_submit <command> [args...]"
    return 1
  }
  local dashboard_port="$(_verl_h200_env_value RAY_DASHBOARD_PORT)"
  dashboard_port="${dashboard_port:-8265}"
  _verl_h200_compose --profile head exec -T ray-head \
    ray job submit \
      --address="http://127.0.0.1:${dashboard_port}" \
      --runtime-env=/workspace/verl/verl/trainer/runtime_env.yaml \
      --no-wait \
      -- "$@"
}

verl_h200_submit_grpo() {
  local nnodes="${1:-${NNODES:-1}}"
  local model_path="${2:-${MODEL_PATH:-/models/Qwen3-8B}}"
  local total_epochs="${3:-${TOTAL_EPOCHS:-1}}"
  local gpus_per_node="${NGPUS_PER_NODE:-$(_verl_h200_env_value GPUS_PER_NODE)}"
  local infer_backend="${INFER_BACKEND:-vllm}"
  gpus_per_node="${gpus_per_node:-8}"

  print -r -- "提交 GRPO: nodes=${nnodes}, gpus/node=${gpus_per_node}, model=${model_path}, epochs=${total_epochs}, rollout=${infer_backend}"
  verl_h200_submit \
    env \
      NNODES="${nnodes}" \
      NGPUS_PER_NODE="${gpus_per_node}" \
      MODEL_PATH="${model_path}" \
      TOTAL_EPOCHS="${total_epochs}" \
      INFER_BACKEND="${infer_backend}" \
    bash examples/grpo_trainer/run_qwen3_8b_fsdp.sh \
      'trainer.logger=["console"]'
}

verl_h200_jobs() {
  local dashboard_port="$(_verl_h200_env_value RAY_DASHBOARD_PORT)"
  dashboard_port="${dashboard_port:-8265}"
  _verl_h200_compose --profile head exec -T ray-head \
    ray job list --address="http://127.0.0.1:${dashboard_port}"
}

verl_h200_job_logs() {
  local submission_id="${1:-}"
  [[ -n "${submission_id}" ]] || {
    _verl_h200_error "用法: verl_h200_job_logs <submission-id>"
    return 1
  }
  local dashboard_port="$(_verl_h200_env_value RAY_DASHBOARD_PORT)"
  dashboard_port="${dashboard_port:-8265}"
  _verl_h200_compose --profile head exec -T ray-head \
    ray job logs "${submission_id}" \
      --address="http://127.0.0.1:${dashboard_port}" \
      --follow
}

verl_h200_job_stop() {
  local submission_id="${1:-}"
  [[ -n "${submission_id}" ]] || {
    _verl_h200_error "用法: verl_h200_job_stop <submission-id>"
    return 1
  }
  local dashboard_port="$(_verl_h200_env_value RAY_DASHBOARD_PORT)"
  dashboard_port="${dashboard_port:-8265}"
  _verl_h200_compose --profile head exec -T ray-head \
    ray job stop "${submission_id}" \
      --address="http://127.0.0.1:${dashboard_port}"
}

verl_h200_help() {
  cat <<'EOF'
verl H200 快捷函数

  verl_h200_prepare
      从 .env.h200.example 创建 .env.h200。

  verl_h200_config [head|worker]
      展开并检查最终 Compose 配置。

  verl_h200_head_up
      在头节点使用已发布/已有镜像启动 Ray Head。

  verl_h200_worker_up
      在工作节点使用已发布/已有镜像加入 Ray 集群。

  verl_h200_pull [head|worker]
      从 GHCR 拉取 H200 镜像。

  verl_h200_build [head|worker]
      不使用 GHCR 时，在当前节点本地构建镜像。

  verl_h200_status
      在头节点查看 Ray 集群资源和节点状态。

  verl_h200_dashboard
      打印 Ray Dashboard 地址。

  verl_h200_shell
      进入 ray-head 容器。

  verl_h200_submit <command> [args...]
      向 Ray Job API 提交任意命令。

  verl_h200_submit_grpo [节点数] [模型路径] [epoch数]
      快速提交 Qwen3 GRPO 示例。
      示例: verl_h200_submit_grpo 4 /models/Qwen3-8B 1

  verl_h200_jobs
      查看 Ray Jobs。

  verl_h200_job_logs <submission-id>
      持续查看指定任务日志。

  verl_h200_job_stop <submission-id>
      停止指定 Ray Job。

  verl_h200_logs [head|worker]
      持续查看容器日志。

  verl_h200_restart [head|worker]
      重启指定角色容器。

  verl_h200_down [head|worker]
      停止并删除当前节点上的 Compose 服务。

可覆盖变量:
  VERL_H200_ENV_FILE      自定义环境文件路径
  VERL_H200_COMPOSE_FILE  自定义 Compose 文件路径
  NNODES / NGPUS_PER_NODE / MODEL_PATH / TOTAL_EPOCHS / INFER_BACKEND
EOF
}

print -r -- ""
print -r -- "[verl H200 helpers loaded]"
print -r -- "用途：快速准备配置、启动 Ray head/worker、提交训练和查看任务。"
print -r -- "首次使用：verl_h200_prepare，然后编辑 .env.h200。"
print -r -- "查看全部命令：verl_h200_help"
