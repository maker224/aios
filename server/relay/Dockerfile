FROM dart:stable AS build
WORKDIR /app
COPY . .
RUN dart compile exe bin/server.dart -o bin/relay

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /app/bin/relay /app/relay
ENV PORT=8080
EXPOSE 8080
CMD ["/app/relay"]
