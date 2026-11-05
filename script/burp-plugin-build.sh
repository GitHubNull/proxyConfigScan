#!/usr/bin/env bash
# Burp 插件 Maven 构建封装（显式 JDK 21，montoya-api 需要 Java 17+）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"

mvn -f "$ROOT_DIR/src/burp-plugin/pom.xml" "${@:-package}"
echo ">> 产物目录: src/burp-plugin/target/"
