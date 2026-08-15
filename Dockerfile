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
