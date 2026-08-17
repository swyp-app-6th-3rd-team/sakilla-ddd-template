#!/bin/bash
# HBase 초기화 래퍼 — pinpointdocker/pinpoint-hbase 이미지의 기동 스크립트를 대체한다.
#
# 이미지 기본 흐름은 다음과 같다.
#   initialize-hbase.sh → start-hbase.sh → configure-hbase.sh → check-table.sh
# 그런데 check-table.sh 가 master 준비 여부를 확인하지 않고 `sleep 15` 후 곧바로
# create 문을 쏜다. master 초기화가 15초를 넘기면 모든 create 가
#   ERROR: org.apache.hadoop.hbase.PleaseHoldException: Master is initializing
# 으로 튕기고, 테이블이 하나도 안 만들어진 채 컨테이너는 Up 으로 남는다.
#
# 이 스크립트는 blind sleep 대신 **실제 준비 상태를 확인**한 뒤 테이블을 만든다.
#
# 함께 고치는 것들(전부 실측으로 필요성이 확인됨):
#   1) ZK quorum  — 이미지가 zoo1,zoo2,zoo3 을 하드코딩. 1노드로 쓰려면 덮어써야 하고
#                   안 그러면 UnknownHostException: zoo2 로 초기화가 끝나지 않는다.
#   2) 타임아웃    — 리전 대량 생성 중 ZK 세션이 만료되면 master 가 죽는다.
#   3) GC         — 이미지 기본 CMS 는 이 워크로드에서 STW 가 길다.
set -u

CONF=/opt/hbase/hbase-2.2.6/conf
HB=/opt/hbase/hbase-2.2.6/bin/hbase

# 1) ZK quorum 을 단일 노드로
sed -i 's|<value>zoo1,zoo2,zoo3</value>|<value>zoo1</value>|' "$CONF/hbase-site.xml"

# 2) 타임아웃 상향
#    주의: 클라이언트만 올려도 소용없다. ZK 서버가 maxSessionTimeout(=20 × tickTime)
#    으로 잘라내므로 zoo1 의 ZOO_TICK_TIME 도 함께 올려야 한다.
#    확인: docker logs <zoo> | grep "negotiated timeout"
#
#    ⚠ hbase.master.wait.on.regionservers.timeout 은 **올리면 안 된다.**
#    이 값은 "실패 판정 상한" 이 아니라 "리전서버를 더 기다리는 시간" 이라,
#    단일 노드에서 이미 count=1 ≥ min=1 을 만족해도 타임아웃까지 대기한다.
#    (180000 으로 줬다가 master 활성화가 3분 지연되는 것을 실측)
#    단일 노드에서는 오히려 짧게 잡아 즉시 진행시킨다.
sed -i 's|</configuration>|<property><name>zookeeper.session.timeout</name><value>180000</value></property><property><name>hbase.rpc.timeout</name><value>180000</value></property><property><name>hbase.client.operation.timeout</name><value>300000</value></property><property><name>hbase.master.wait.on.regionservers.timeout</name><value>15000</value></property><property><name>hbase.master.wait.on.regionservers.mintostart</name><value>1</value></property><property><name>hbase.master.wait.on.regionservers.interval</name><value>1500</value></property></configuration>|' "$CONF/hbase-site.xml"

# 3) GC 교체. HBASE_OPTS 는 환경변수로 못 넘긴다 — hbase-env.sh 가 자기 값으로 덮어쓴다.
sed -i 's|^export HBASE_OPTS=.*|export HBASE_OPTS="-XX:+UseParallelGC"|' "$CONF/hbase-env.sh"

# 4) 기동
"${HBASE_HOME}/bin/start-hbase.sh"
/usr/local/bin/configure-hbase.sh

# 5) master 가 실제로 **DDL** 을 받을 때까지 대기
#
# 주의: `list` 로 확인하면 안 된다. list 는 master 초기화가 끝나기 전에도 성공하는데
# create 는 여전히 PleaseHoldException 으로 튕긴다(실측: "READY after 1 checks" 직후
# create 4건 전부 실패). 준비 여부는 **실제로 하려는 작업(DDL)으로** 확인해야 한다.
# → 임시 테이블을 만들어보고, 성공하면 지운다.
echo "[init] waiting for HBase master to accept DDL..."
PROBE="__pinpoint_init_probe__"
for i in $(seq 1 120); do
  out=$(printf "create '%s','c'\n" "$PROBE" | $HB shell -n 2>&1)
  if echo "$out" | grep -q "PleaseHoldException"; then
    echo "[init] master still initializing... (${i})"
  elif echo "$out" | grep -qE "Created table|already exists"; then
    echo "[init] master ACCEPTS DDL after ${i} checks"
    printf "disable '%s'\ndrop '%s'\n" "$PROBE" "$PROBE" | $HB shell -n >/dev/null 2>&1
    break
  else
    echo "[init] not ready yet... (${i})"
  fi
  sleep 10
done

# 5-1) 리전 pre-split 수를 줄인다 (PINPOINT_HBASE_NUMREGIONS, 기본 4)
#
# hbase-create.hbase 는 TraceV2 를 NUMREGIONS => 256 으로 만든다. 프로덕션
# 클러스터 기준값이라 단일 노드 개발/검증 환경에는 과하다. 특히 리전 생성이
# 16 스레드로 동시에 돌아가는데, 에뮬레이션 환경(arm64 에서 amd64)에서는
# 이 동시성이 JVM 을 213 초까지 통째로 멈추게 만든다.
#
#   "We slept 213075ms instead of 3000ms"
#   "JvmPauseMonitor: Detected pause in JVM or host machine (eg GC)"
#
# GC 문제로 보이지만 아니다 — ParallelGC 로 바꿔도 정지가 오히려 길어졌고
# (190s → 213s), 힙은 2G 중 1.8G, 호스트 메모리는 15.6G 중 4G 만 쓰고 있었다.
# JvmPauseMonitor 문구대로 "JVM **또는 호스트**" 정지이며, 실체는 에뮬레이션
# 계층에서 스레드 스케줄링이 무너지는 것이다.
#
# 리전 수를 줄이면 동시 생성 스레드가 줄어 이 문제를 피한다.
# 운영(x86 네이티브)에서는 256 을 그대로 쓰는 것이 맞다 —
# PINPOINT_HBASE_NUMREGIONS=256 으로 원복한다.
NUMREGIONS="${PINPOINT_HBASE_NUMREGIONS:-4}"
if [ "$NUMREGIONS" != "256" ]; then
  echo "[init] reducing TraceV2 pre-split: NUMREGIONS 256 -> $NUMREGIONS"
  sed -i "s|NUMREGIONS => 256|NUMREGIONS => $NUMREGIONS|g" /opt/hbase/hbase-create.hbase
fi

# 6) 테이블 생성 (이미 있으면 건너뛴다 — 재기동 시 데이터 보존)
if echo "exists 'AgentId'" | $HB shell -n 2>&1 | grep -q "does exist"; then
  echo "[init] tables already exist, skipping creation"
else
  echo "[init] creating tables (this takes a few minutes)"
  $HB shell /opt/hbase/hbase-create.hbase
fi

echo "[init] done. table_count=$(echo 'list' | $HB shell -n 2>&1 | grep -cE '^[A-Za-z][A-Za-z0-9_]*$')"

# 원본 CMD 와 동일하게 컨테이너를 살려둔다.
tail -f /dev/null
