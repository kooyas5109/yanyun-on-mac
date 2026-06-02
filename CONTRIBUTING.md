# Contributing

欢迎贡献！不一定要写代码：

- **报 bug**：开个 issue，附上系统版本和复现步骤即可
- **测试**：在不同型号的 Mac 上跑跑看，反馈兼容性
- **改文档**：错别字、过时的步骤，直接提交 PR 就行

## 提代码的流程

1. Fork → 新建分支（`feat/xxx` 或 `fix/xxx`）
2. 改完确认本地能跑：`bash scripts/dev-deploy.sh`
3. Commit 用英文，遵循 [Conventional Commits](https://www.conventionalcommits.org/)：
   ```
   feat: add controller support
   fix(wine): handle modal popup focus
   docs: update FAQ
   ```
4. 发 Pull Request，说清楚改了什么、为什么改

## 代码规范

- **Swift**：跟现有代码风格走，可读性优先
- **C**：4 空格缩进，注释解释「为什么」不是「是什么」
- **Shell**：`set -e`，路径用引号包起来

## PR 自检

- [ ] `scripts/dev-deploy.sh` 能跑通
- [ ] 没有提交密钥、证书或个人信息
- [ ] PR 标题符合 Conventional Commits

## 还有问题？

直接开 issue 问就行，不用客气。
