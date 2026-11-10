#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nanocode.h"

#define SESSION "01900000-0000-7000-8000-000000000001"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static NanocodeHandle *runtime;
static int opened, finished, failed;

static void send(const char *json) {
  nanocode_send(runtime, (const uint8_t *)json, strlen(json));
}

static void receive(void *context, const uint8_t *data, size_t length) {
  (void)context;
  char *message = strndup((const char *)data, length);
  unsigned long long call;
  const char *found = strstr(message, "{\"call\":{");
  const char *id = found ? strstr(found, "\"id\":") : NULL;
  if (id && sscanf(id, "\"id\":%llu", &call) == 1) {
    char reply[256];
    if (strstr(message, "\"kind\":\"tool\"")) {
      const char *input = strstr(message, "\"input\":");
      printf("[tool] C received %.*s\n", input ? (int)strcspn(input + 8, "}") + 1 : 0, input ? input + 8 : "");
      snprintf(reply, sizeof reply, "{\"command\":{\"reply\":{\"id\":%llu,\"ok\":\"noted\"}}}", call);
    } else {
      snprintf(reply, sizeof reply, "{\"command\":{\"reply\":{\"id\":%llu,\"error\":\"this program does not answer that call\"}}}", call);
    }
    send(reply);
  }
  pthread_mutex_lock(&lock);
  if (strstr(message, "{\"reply\":1,")) {
    if (strstr(message, "\"error\"")) { printf("[open] %s\n", message); failed = 1; }
    opened = 1;
  }
  if (strstr(message, "\"fatal\"") || strstr(message, "{\"reply\":2,\"error\"")) { printf("[error] %s\n", message); failed = 1; }
  const char *text = strstr(message, "\"type\":\"assistant.message\"");
  const char *said = text ? strstr(text, "\"text\":\"") : NULL;
  if (said) printf("[assistant] %.*s\n", (int)strcspn(said + 8, "\""), said + 8);
  if (strstr(message, "\"turn\":{") && (strstr(message, "\"status\":\"completed\"") || strstr(message, "\"status\":\"failed\""))) {
    printf("[turn] %s\n", strstr(message, "\"status\":\"completed\"") ? "completed" : "failed");
    finished = 1;
  }
  pthread_cond_broadcast(&changed);
  pthread_mutex_unlock(&lock);
  free(message);
}

static void until(int *flag) {
  pthread_mutex_lock(&lock);
  while (!*flag && !failed) pthread_cond_wait(&changed, &lock);
  pthread_mutex_unlock(&lock);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s ENDPOINT SHELL_RESOURCES\n", argv[0]);
    return 2;
  }
  char directory[] = "/tmp/libnanocode-XXXXXX";
  if (!mkdtemp(directory)) return 1;
  char json[4096];
  snprintf(json, sizeof json, "{\"data_dir\":\"%s\",\"shell\":\"%s\"}", directory, argv[2]);
  runtime = nanocode_start((const uint8_t *)json, strlen(json), receive, NULL);
  if (!runtime) return 1;
  snprintf(json, sizeof json,
           "{\"id\":1,\"command\":{\"open\":{\"session_id\":\"" SESSION "\",\"provider\":\"claude\",\"model\":\"claude-haiku-5-5\","
           "\"endpoint\":\"%s\",\"auth\":{\"api_key\":\"test\"},\"workspace_tools\":\"none\",\"web_search\":false,"
           "\"tools\":[{\"name\":\"note\",\"description\":\"Records a number.\",\"parameters\":{\"type\":\"object\","
           "\"properties\":{\"lucky\":{\"type\":\"number\"},\"id\":{\"type\":\"string\"}},\"required\":[\"lucky\",\"id\"]}}]}}}",
           argv[1]);
  send(json);
  until(&opened);
  if (!failed) {
    send("{\"id\":2,\"command\":{\"submit\":{\"session\":\"" SESSION "\",\"request_id\":\"turn-1\",\"prompt\":\"Note a number.\"}}}");
    until(&finished);
  }
  nanocode_stop(runtime);
  return failed;
}
