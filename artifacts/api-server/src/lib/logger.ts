import pino, { type LoggerOptions } from "pino";
import {
  LOG_REDACT_PATHS,
  requestLogFields,
  scrubLogFields,
  scrubLogString,
  scrubLogValue,
  scrubSerializedError,
} from "./requestLog";

const isProduction = process.env.NODE_ENV === "production";

/**
 * pino's error serializer, then the secret scrub: an error from an HTTP client
 * (a Privy call, say) loses the request and response it carries, with our own
 * Authorization header in them (docs/privy-account-layer.md §3.14).
 */
export function logErrorSerializer(err: unknown): unknown {
  return scrubSerializedError(err instanceof Error ? pino.stdSerializers.err(err) : err, logErrorSerializer);
}

/**
 * The request line's fields, the status code and the scrubbed error. pino-http
 * uses them (app.ts), and so does every other log line, so a `req` or `res`
 * logged by hand (an HTTP client's request body, say) is cut down the same way.
 */
export const httpLogSerializers = {
  req: (req: Parameters<typeof requestLogFields>[0]) => requestLogFields(req, process.env.NODE_ENV === "production"),
  res: (res: { statusCode: number }) => ({ statusCode: res.statusCode }),
  // pino-http replaces the logger's own error serializer, so it is passed again.
  err: logErrorSerializer,
};

/** Redaction and serializers for every log line; the request log test uses them too. */
export const loggerOptions: LoggerOptions = {
  level: process.env.LOG_LEVEL ?? "info",
  redact: LOG_REDACT_PATHS,
  serializers: httpLogSerializers,
  formatters: { log: (obj) => scrubLogFields(obj, logErrorSerializer) },
  hooks: {
    // Messages and their %s, %o and %j arguments are masked too. Without a
    // message pino copies the error's raw message into `msg`, so the scrubbed
    // one is passed instead.
    logMethod(args, method) {
      const list = [...args] as unknown[];
      const first = list[0];
      const err = first instanceof Error ? first : (first as { err?: unknown } | null)?.err;
      if (list.length === 1 && err instanceof Error) list.push(err.message);
      // The merge object, if any, goes through formatters.log; everything after the message is an argument.
      const firstArg = typeof first === "string" ? 1 : 2;
      const scrubbed = list.map((a, i) => {
        if (typeof a === "string") return scrubLogString(a);
        if (i < firstArg || typeof a !== "object" || a === null) return a;
        return a instanceof Error ? scrubLogString(String(a)) : scrubLogValue(a, logErrorSerializer);
      });
      return method.apply(this, scrubbed as Parameters<typeof method>);
    },
  },
};

/**
 * A child logger's fields (logger.child({ token })) are scrubbed like a log
 * call's. pino's formatters.bindings cannot do it: a child resets that
 * formatter (pino 9, lib/proto.js child()). Children inherit this wrapper.
 */
export function withScrubbedChildBindings<T extends pino.Logger>(log: T): T {
  const child = log.child;
  log.child = function (this: T, bindings: pino.Bindings, options?: pino.ChildLoggerOptions) {
    return child.call(this, scrubLogFields(bindings, logErrorSerializer), options);
  } as T["child"];
  return log;
}

export const logger = withScrubbedChildBindings(
  pino({
    ...loggerOptions,
    ...(isProduction
      ? {}
      : {
          transport: {
            target: "pino-pretty",
            options: { colorize: true },
          },
        }),
  }),
);
