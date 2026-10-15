# Redmine SVN Authz

[![CI](https://github.com/xxbbzy/redmine_svn_authz/actions/workflows/ci.yml/badge.svg)](https://github.com/xxbbzy/redmine_svn_authz/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xxbbzy/redmine_svn_authz)](https://github.com/xxbbzy/redmine_svn_authz/releases)
[![Redmine](https://img.shields.io/badge/Redmine-5.1%20%7C%206.x-B32024)](https://www.redmine.org/)
[![License: GPL v2+](https://img.shields.io/badge/License-GPL%20v2%2B-blue.svg)](LICENSE)

[English](README.md) | 简体中文

在 Redmine 的 Subversion 版本库中，用与 svn 服务器相同的 **`authz` 规则**实现目录级读权限。

Redmine 自带的权限只能控制整个版本库：拥有「浏览版本库」权限的人能看到所有路径。
装上本插件后，在**同一个**版本库里，用户 A 只能看到 `/dirA`，用户 B 只能看到 `/dirB`。所有展示版本库内容的地方都遵守同样的规则。

## 功能

- **与 svn 规则一致**：规则的解析和判定移植自 Subversion 1.14（`libsvn_repos/authz*.c`），并用真实的 `svnauthz` 工具做了对照测试。支持：
  - `[groups]`、`[aliases]`、`~` 取反
  - `$anonymous` / `$authenticated`
  - `[版本库:/path]` 段
  - **通配段**（`[:glob:/trunk/src/*]`、`**`、`*.c` 等）
- **覆盖所有展示内容的位置**：目录浏览、文件查看、下载、追溯、diff、修订列表和详情、活动、搜索，以及问题的「关联的修订」。
- **两种规则来源**：
  - 直接读取 svn 服务器正在使用的 authz 文件（如 Apache 的 `AuthzSVNAccessFile`），文件修改后自动生效
  - 在 Redmine 中维护（原文编辑器或规则表格），可同时导出到文件供 svn 服务器使用
- **按登录名匹配用户**：authz 中的用户名就是 Redmine 的登录名。
- **拒绝优先**：规则无效或文件不可读时，受限用户看不到任何内容。管理员和拥有「不受目录权限限制」权限的角色不受限制。
- **以用户身份预览**：查看适用于某个登录名的段，以及它对某个路径的权限。

## 环境要求

- Redmine 5.1 或 6.x（CI 中测试 5.1 和 6.1）
- Subversion 版本库（其他类型的版本库不受影响）
- SQLite、MySQL / MariaDB 或 PostgreSQL

## 安装

```sh
cd $REDMINE_ROOT/plugins
git clone https://github.com/xxbbzy/redmine_svn_authz.git
cd ..
bin/rails redmine:plugins:migrate RAILS_ENV=production
# 重启 Redmine
```

插件目录名必须是 `redmine_svn_authz`。

卸载：先执行 `bin/rails redmine:plugins:migrate NAME=redmine_svn_authz VERSION=0 RAILS_ENV=production`，再删除插件目录并重启 Redmine。

## 配置

1. **管理 → 插件 → Redmine SVN Authz → 配置**：填写允许读取或导出 authz 文件的目录（每行一个，如 `/etc/svn`）。其他路径一律拒绝。
2. **管理 → 角色和权限**（「版本库」模块下）：
   - 管理目录权限：可以编辑版本库的规则
   - 不受目录权限限制：能看到全部内容（管理员始终如此）
3. 打开版本库页面，点右上角的 **目录权限**：

   | 设置 | 说明 |
   |---|---|
   | 规则来源 | 「在 Redmine 中维护」或「读取服务器上的 authz 文件」 |
   | authz 版本库名 | 用于匹配 `[名称:/path]` 段，默认取版本库根 URL 的最后一段 |
   | 版本库 URL 对应路径 | Redmine 版本库 URL 在 svn 仓库中对应的路径（如 `/trunk`），自动识别 |
   | 导出到文件 | 可选。保存时把规则写入该文件，让 svn 和 Redmine 共用一份规则 |

authz 中的路径以 **svn 仓库根**为基准。即使 Redmine 版本库 URL 是 `svn://host/repo/trunk`，规则也仍按 `[/trunk/dirA]` 来写。

### 示例：稀疏检出

各组都能读取父目录，但默认读不到任何模块，再逐个授权自己的模块：

```ini
[groups]
team_a = alice
team_b = bob

[/trunk]
@team_a = r
@team_b = r
[/trunk/src]
@team_a = r
@team_b = r

# 默认不能读取任何模块
[:glob:/trunk/src/*]
@team_a =
@team_b =

[/trunk/src/module_a]
@team_a = rw
[/trunk/src/module_b]
@team_b = rw
```

效果：
- alice 浏览 `/trunk/src` 时只能看到 `module_a`，`module_b` 和 `/trunk/src/Makefile` 都不可见
- 只改动了 `module_b` 的提交不会出现在她的修订列表、活动和搜索结果中

和 svn 一样，同一深度匹配到的多个段之间**顺序有意义**：靠后的段优先。`[/trunk/src/module_a]` 必须写在 `[:glob:/trunk/src/*]` 之后。

## 规则语义

与 Subversion 1.10+ 一致：

- **判定方式**：沿路径逐级匹配，由匹配到的最深一级规则决定权限。
  - 同一级有多个通配段匹配时，在文件中**靠后**的段优先
  - 该级没有匹配时继承上一级
  - 完全没有匹配时拒绝访问
- **段的适用范围**：只考虑段中至少有一条条目命中该用户的段。用户在一个段中的权限是所有命中条目的并集。
- 同一路径下，`[版本库:/path]` 段优先于 `[/path]` 段。
- 匿名用户只匹配 `*`、`$anonymous`、`~$authenticated`。
- svn 拒绝加载的文件这里也会报错，校验规则相同，例如：
  - 段名重复
  - 非规范路径（`/a/`、`/a//b`）
  - 只写权限 `w`
  - `~*`
  - 未定义的组或别名
- 在 Redmine 中只有读权限（`r`）有意义。

## 受控范围

| 位置 | 行为 |
|---|---|
| 目录浏览 | 只列出可读的条目，以及通往可读内容的中间目录；中间目录不显示最后修订和大小 |
| 文件查看、下载、追溯 | 不可读时返回 `403` |
| diff | 去掉不可读的文件；缓存按有效规则分开 |
| 修订列表、路径历史 | 只显示至少改动了一个可读路径的提交 |
| 修订详情 | 只列出可读的变更；没有可读变更时返回 `403` |
| 活动、搜索、问题的关联修订 | 与修订列表相同，通过 `Changeset.visible` 统一过滤 |
| 统计 | 受限用户返回 `403`（统计覆盖整个版本库） |

## 已知限制

- 只要提交改动了任意一个可读路径，就会完整显示提交说明，与 `svn log` 的行为一致。
- 提交说明中的 `refs #123`、`fixes #123` 会在问题中写入 "Applied in changeset rN" 等内容，这部分不受本插件控制。
- 修订页的「上一个 / 下一个」链接可能指向用户不可见的修订，但只泄露修订号，点进去会返回 403。
- 和 svn 一样，判断「目录下是否还有可读内容」时不会检查实际存在哪些路径。所以 `[:glob:/**/public]` 这类规则可能让空目录出现在目录树中。
- MySQL 使用大小写不敏感的排序规则时，`changes.path` 的匹配也会忽略大小写。

## 性能

- **规则不含通配符**：「用户能看到哪些提交」直接用 SQL 前缀条件判断，没有额外开销。
- **规则含通配符**：这类规则无法写成跨数据库通用的 SQL，插件会把每组有效规则下的可见提交算好存进数据表。权限完全相同的用户共用一份。
  - 之后只增量处理新拉取的提交
  - 修改规则时清空
  - 超过 30 天未使用的数据会自动删除
  - 大型版本库第一次计算可能需要几秒

## 开发

全部在 Docker 中进行，本机不需要安装 Ruby。

```sh
# 测试（Redmine 6；用 REDMINE_VERSION=5.1 测试 Redmine 5.1；用 DB=postgresql 或 DB=mysql 测试其他数据库）
docker/run-tests.sh

# 核心解析和判定逻辑的测试，可脱离 Redmine 运行（Ruby >= 2.6）
ruby test/unit/authz_core_test.rb

# 与真实 svn 对照：随机生成 authz 文件比较结果（需要 `svnauthz`）
docker run --rm -v "$PWD":/plugin:ro -e SVN_AUTHZ_FUZZ=300 redmine-svn-authz-dev:6 \
  ruby /plugin/test/unit/svnauthz_differential_test.rb

# 本地体验：http://localhost:3000
docker compose up -d --build
docker compose exec redmine bin/rails runner plugins/redmine_svn_authz/docker/seed_demo.rb
```

演示数据会创建用户 `alice` 和 `bob`（密码 `password123`），以及一个包含两个版本库的项目：
- `demo`：alice 只能看到 `/trunk/dirA`，bob 只能看到 `/trunk/dirB`
- `sparse`：上面的稀疏检出示例

参与贡献请看 [CONTRIBUTING.md](CONTRIBUTING.md)，版本历史见 [CHANGELOG.md](CHANGELOG.md)。

## 安全

本插件负责访问控制。发现安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要提交公开 issue。

## 许可证

Copyright (C) 2026 xxbbzy

本程序是自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证第 2 版，或（由你选择）任何更新的版本，重新分发和/或修改它。详见 [LICENSE](LICENSE)。
