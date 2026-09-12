#!/bin/sh
IFS= read -r initialize
case "$initialize" in *'"initialize"'*) ;; *) exit 1 ;; esac
if [ "$1" = "timeout" ]; then
    IFS= read -r blocked
    exit 0
fi
printf '%s\n' '{"id":0,"result":{}}'
IFS= read -r initialized
IFS= read -r request
case "$request" in *'"account/rateLimits/read"'*) ;; *) exit 1 ;; esac
case "$1" in
    exit) exit 1 ;;
    error) printf '%s\n' '{"id":1,"error":{"code":-1,"message":"fixture error"}}' ;;
    invalid) printf '%s\n' '{"id":1,"result":{}}' ;;
    *)
        printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1789435997}}}}'
        printf '%s' '{"id":1,"result":{"rateLimitsByLimitId":{"codex":{"primary":'
        sleep 0.02
        printf '%s\n' '{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1789839438},"secondary":null}}}}'
        ;;
esac
IFS= read -r until_closed
