# 빌드 스테이지
FROM amazoncorretto:25 AS builder
WORKDIR /workspace

# amazoncorretto 이미지는 Amazon Linux 최소 구성이라 findutils(xargs) 가 없다.
# Gradle wrapper 스크립트가 xargs 를 쓰므로 없으면 "xargs is not available" 로 실패한다.
RUN yum install -y findutils && yum clean all

# 의존성 레이어를 소스와 분리해 캐시 적중률을 높인다.
COPY gradlew ./
COPY gradle ./gradle
COPY build.gradle settings.gradle ./
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon || true

COPY src ./src
RUN ./gradlew bootJar --no-daemon -x test

# Pinpoint 에이전트 스테이지 (옵트인)
#
# PINPOINT_ENABLED=false 가 기본이라 평소에는 이 스테이지가 빈 디렉터리만 만든다.
# 에이전트를 안 쓰는 프로젝트에는 흔적이 거의 없다.
#   docker build --build-arg PINPOINT_ENABLED=true .
#
# 에이전트와 collector 는 반드시 같은 3.1.x 여야 한다 — 3.1.0 부터 span 전송
# 기본값이 BATCH 로 바뀌었고 이는 3.1.0+ collector 를 요구한다.
# 또한 Java 25 를 지원하는 에이전트는 3.1.x 가 처음이다(3.0.x 는 21 까지).
FROM alpine:3.20 AS pinpoint
ARG PINPOINT_ENABLED=false
ARG PINPOINT_VERSION=3.1.0
WORKDIR /stage
RUN mkdir -p /stage/pinpoint-agent && \
    if [ "$PINPOINT_ENABLED" = "true" ]; then \
      apk add --no-cache curl tar && \
      curl -fsSL -o /tmp/agent.tar.gz \
        "https://github.com/pinpoint-apm/pinpoint/releases/download/v${PINPOINT_VERSION}/pinpoint-agent-${PINPOINT_VERSION}.tar.gz" && \
      tar xzf /tmp/agent.tar.gz -C /tmp && \
      cp -r "/tmp/pinpoint-agent-${PINPOINT_VERSION}/." /stage/pinpoint-agent/ && \
      rm -rf /tmp/agent.tar.gz "/tmp/pinpoint-agent-${PINPOINT_VERSION}"; \
    fi

# 실행 스테이지
FROM amazoncorretto:25-alpine
WORKDIR /app

# 헬스체크용 wget 과 타임존 데이터
RUN apk add --no-cache wget tzdata && \
    ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime

# root 로 실행하지 않는다.
RUN addgroup -S app && adduser -S app -G app

# 로그 디렉터리를 root 권한일 때 미리 만들고 소유권을 넘긴다.
#
# 이 순서가 중요하다. 도커는 빈 named volume 을 마운트할 때 컨테이너 이미지의
# 해당 경로 소유권·권한을 볼륨에 복사한다. 디렉터리가 없으면 root:root 로 만들어지고,
# non-root 로 실행되는 앱이 로그 파일을 쓰지 못한다.
#   → java.io.FileNotFoundException: /app/logs/error/error.log (Permission denied)
#
# USER 를 바꾸기 전에 만들어야 chown 이 먹는다.
RUN mkdir -p /app/logs/error /app/logs/warn /app/logs/info && \
    chown -R app:app /app/logs

# Pinpoint 에이전트를 이미지에 넣는다.
# PINPOINT_ENABLED=false 면 빈 디렉터리만 복사되므로 사실상 무해하다.
# 에이전트는 로그를 자기 디렉터리 아래에 쓰므로 소유권을 app 에 넘긴다.
COPY --from=pinpoint --chown=app:app /stage/pinpoint-agent /pinpoint-agent

USER app

COPY --from=builder --chown=app:app /workspace/build/libs/*.jar app.jar

# 컨테이너 안의 로그 위치. docker-compose 가 이 경로를 볼륨에 연결한다.
ENV LOG_DIR=/app/logs

EXPOSE 8080

# 컨테이너 메모리 한도를 JVM 이 인식하게 한다.
ENTRYPOINT ["java", \
  "-XX:MaxRAMPercentage=75.0", \
  "-XX:+UseContainerSupport", \
  "-Duser.timezone=Asia/Seoul", \
  "-jar", "app.jar"]
