FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /app
COPY . .
RUN cargo build --release

FROM alpine:3.20
WORKDIR /app
COPY --from=build /app/target/release/aios-relay /app/aios-relay
ENV PORT=8080
EXPOSE 8080
CMD ["/app/aios-relay"]
