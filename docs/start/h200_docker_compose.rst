H200 集群 Docker Compose 启动指南
==================================

``docker-compose.h200.yaml`` 使用 Ray head/worker 模式组织多节点 H200 集群。
Docker Compose 本身不是跨主机编排器，因此需要在每台物理节点上运行同一份
Compose 文件：头节点启用 ``head`` profile，其余节点启用 ``worker`` profile。

快捷函数
--------

仓库根目录的 ``functions.zsh`` 封装了常用 Compose 和 Ray 命令。每次加载时都会
打印用途和入口提示：

.. code-block:: bash

   source functions.zsh
   verl_h200_help

首次使用：

.. code-block:: bash

   verl_h200_prepare
   # 编辑 .env.h200 后，在头节点运行：
   verl_h200_head_up
   # 在每台工作节点运行：
   verl_h200_worker_up

头节点常用命令：

.. code-block:: bash

   verl_h200_status
   verl_h200_dashboard
   verl_h200_submit_grpo 4 /models/Qwen3-8B 1
   verl_h200_jobs

前置条件
--------

- 每台节点已安装 Docker Compose v2 和 NVIDIA Container Toolkit；
- 每台节点的 ``docker run --rm --gpus all ... nvidia-smi`` 能看到 H200；
- 节点之间允许 Ray/NCCL 的东西向通信；至少开放 ``6379`` 和 ``8265``，若集群
  防火墙限制动态端口，还需要由管理员配置 Ray Worker 端口范围；
- 仓库位于每台节点的相同路径，或由共享文件系统提供；
- 数据、模型、checkpoint 和 Hugging Face 缓存目录已经创建，推荐使用共享存储。

准备环境文件
------------

在每台节点执行：

.. code-block:: bash

   cd /path/to/verl
   cp .env.h200.example .env.h200

所有节点的 ``RAY_HEAD_IP`` 必须填写头节点 IP。每台机器的 ``NODE_IP`` 必须填写
当前机器自己的可互通 IP。根据实际节点修改 ``GPUS_PER_NODE``、``CPUS_PER_NODE``
和四个共享目录。InfiniBand 网卡名称、HCA 和 GID 由集群管理员确认，不要直接复制
示例值。

构建镜像
--------

Compose 镜像基于仓库文档中的预构建 vLLM 镜像，只额外安装 ``uv``。可以在每台节点
分别构建，也可以在一台机器构建后推送到集群内部镜像仓库。

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head build

默认配置会直接使用 GitHub Action 发布的镜像：

.. code-block:: text

   ghcr.io/qingtianrobot/verl:h200-latest

如果该 GHCR Package 是私有的，需要先在每台节点登录：

.. code-block:: bash

   echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin

加载 ``functions.zsh`` 后，可直接执行 ``verl_h200_pull head`` 或
``verl_h200_pull worker``。需要完全本地构建时，把 ``VERL_IMAGE`` 改为本地名称，
把 ``VERL_PULL_POLICY`` 改为 ``never``，再执行 ``verl_h200_build``。

GitHub Action 自动发布
----------------------

``.github/workflows/publish-h200-image.yml`` 会在以下情况构建并推送镜像：

- push 到 ``main``；
- push ``v*`` 版本标签；
- 在 GitHub Actions 页面手动运行。

默认发布标签：

.. code-block:: text

   ghcr.io/qingtianrobot/verl:h200-latest
   ghcr.io/qingtianrobot/verl:h200-main
   ghcr.io/qingtianrobot/verl:h200-sha-<commit>
   ghcr.io/qingtianrobot/verl:h200-v1.2.3

工作流使用仓库自带的 ``GITHUB_TOKEN``，仓库 Actions 设置必须允许
``Read and write permissions``，GitHub Organization 也必须允许创建 Package。

本地仓库当前若仍指向上游，可在确认权限后切换远程并推送：

.. code-block:: bash

   git remote set-url origin git@github.com:QingTianRobot/verl.git
   git push -u origin main

启动 Ray 集群
--------------

只在头节点执行：

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head up -d ray-head

在每一台工作节点执行：

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile worker up -d ray-worker

工作节点会持续等待 ``RAY_HEAD_IP:RAY_PORT``，头节点可用后自动加入 Ray 集群。

检查与进入头节点
----------------

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head exec ray-head ray status

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head exec ray-head bash

Dashboard 地址是 ``http://<RAY_HEAD_IP>:8265``。

提交 verl 训练
--------------

推荐从头节点容器使用 Ray Job API 提交。下面以四节点、每节点八张 H200 的 GRPO
脚本为例；模型和数据路径需要与 ``.env.h200`` 的挂载目录对应。

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head exec ray-head bash

进入容器后执行：

.. code-block:: bash

   cd /workspace/verl
   ray job submit \
     --address=http://127.0.0.1:8265 \
     --runtime-env=verl/trainer/runtime_env.yaml \
     --no-wait -- \
     env NNODES=4 \
         NGPUS_PER_NODE=8 \
         MODEL_PATH=/models/Qwen3-8B \
         TOTAL_EPOCHS=1 \
     bash examples/grpo_trainer/run_qwen3_8b_fsdp.sh \
       'trainer.logger=["console"]'

查看任务：

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head exec ray-head ray job list \
       --address=http://127.0.0.1:8265

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head exec ray-head ray job logs <submission-id> \
       --address=http://127.0.0.1:8265 --follow

停止集群
--------

先在所有工作节点停止 Worker，再在头节点停止 Head：

.. code-block:: bash

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile worker down

   docker compose --env-file .env.h200 \
     -f docker-compose.h200.yaml \
     --profile head down

安全与网络说明
--------------

该 Compose 使用 ``network_mode: host`` 和 ``privileged: true``，以减少多节点 Ray、
NCCL、InfiniBand 和 GPU 设备映射的阻力，只应在可信训练节点和可信镜像中使用。
如果集群安全策略不允许 privileged 容器，应由管理员改为精确映射
``/dev/infiniband``、GPU 设备和所需 capabilities。
