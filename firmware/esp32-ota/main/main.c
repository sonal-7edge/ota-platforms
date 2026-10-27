/*
 * ESP32 OTA reference firmware.
 *
 * On every boot the firmware:
 *   1. reports its version, the slot it runs from and that slot's OTA state
 *   2. reads the identity written at the factory (NVS namespace "factory")
 *   3. connects to the network
 *   4. runs a self-test (identity present and network up)
 *   5. if this image is on trial after an update, confirms it when the
 *      self-test passes, or asks the bootloader to roll back when it fails
 *   6. prints one OTA_STATUS line that scripts and the fleet view can read
 */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "protocol_examples_common.h"

static const char *TAG = "ota_app";

#define IDENTITY_NAMESPACE "factory"
#define HEARTBEAT_PERIOD_MS (30 * 1000)

typedef struct {
    char serial[32];
    char hw_rev[32];
} device_identity_t;

static const char *ota_state_name(esp_ota_img_states_t state)
{
    switch (state) {
    case ESP_OTA_IMG_NEW:            return "new";
    case ESP_OTA_IMG_PENDING_VERIFY: return "pending_verify";
    case ESP_OTA_IMG_VALID:          return "valid";
    case ESP_OTA_IMG_INVALID:        return "invalid";
    case ESP_OTA_IMG_ABORTED:        return "aborted";
    case ESP_OTA_IMG_UNDEFINED:      return "undefined";
    default:                         return "unknown";
    }
}

/* Open NVS without erasing it: erasing would also delete the factory identity. */
static bool init_storage(void)
{
    esp_err_t err = nvs_flash_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS init failed: %s (not erasing, identity would be lost)", esp_err_to_name(err));
        return false;
    }
    return true;
}

static bool load_identity(device_identity_t *id)
{
    nvs_handle_t handle;
    esp_err_t err = nvs_open(IDENTITY_NAMESPACE, NVS_READONLY, &handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "No factory identity: %s", esp_err_to_name(err));
        return false;
    }

    size_t len = sizeof(id->serial);
    esp_err_t err_serial = nvs_get_str(handle, "serial", id->serial, &len);
    len = sizeof(id->hw_rev);
    esp_err_t err_hw = nvs_get_str(handle, "hw_rev", id->hw_rev, &len);
    nvs_close(handle);

    if (err_serial != ESP_OK || err_hw != ESP_OK) {
        ESP_LOGE(TAG, "Factory identity incomplete (serial: %s, hw_rev: %s)",
                 esp_err_to_name(err_serial), esp_err_to_name(err_hw));
        return false;
    }
    return true;
}

static bool connect_network(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_err_t err = example_connect();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Network connection failed: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}

static void heartbeat_task(void *arg)
{
    const char *serial = (const char *)arg;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(HEARTBEAT_PERIOD_MS));
        ESP_LOGI(TAG, "heartbeat serial=%s uptime_s=%lld free_heap=%lu",
                 serial, esp_timer_get_time() / 1000000LL, (unsigned long)esp_get_free_heap_size());
    }
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();
    const esp_partition_t *running = esp_ota_get_running_partition();

    esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
    esp_err_t state_err = esp_ota_get_state_partition(running, &state);
    const char *state_text = (state_err == ESP_OK) ? ota_state_name(state) : "none";

    ESP_LOGI(TAG, "firmware %s, running from %s at 0x%06lx, OTA state %s",
             app->version, running->label, (unsigned long)running->address, state_text);

    /* Self-test: what this image needs to be useful. */
    static device_identity_t identity = { .serial = "unknown", .hw_rev = "unknown" };
    bool storage_ok = init_storage();
    bool identity_ok = storage_ok && load_identity(&identity);
    bool network_ok = connect_network();
    bool self_test_ok = identity_ok && network_ok;

    ESP_LOGI(TAG, "self-test %s (identity %s, network %s)",
             self_test_ok ? "passed" : "failed",
             identity_ok ? "ok" : "missing", network_ok ? "ok" : "down");

    /* Only an image on trial after an OTA update is confirmed or rolled back here. */
    const char *action = "none";
    if (state_err == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        if (self_test_ok) {
            ESP_ERROR_CHECK(esp_ota_mark_app_valid_cancel_rollback());
            action = "marked_valid";
            ESP_LOGI(TAG, "new firmware marked valid, rollback cancelled");
        } else {
            action = "rollback";
            printf("OTA_STATUS {\"serial\":\"%s\",\"version\":\"%s\",\"partition\":\"%s\","
                   "\"state\":\"%s\",\"self_test\":\"fail\",\"action\":\"%s\"}\n",
                   identity.serial, app->version, running->label, state_text, action);
            ESP_LOGE(TAG, "self-test failed on trial boot, rolling back");
            esp_ota_mark_app_invalid_rollback_and_reboot();
            return; /* not reached unless there is no previous image to roll back to */
        }
    }

    printf("OTA_STATUS {\"serial\":\"%s\",\"version\":\"%s\",\"partition\":\"%s\","
           "\"state\":\"%s\",\"self_test\":\"%s\",\"action\":\"%s\"}\n",
           identity.serial, app->version, running->label, state_text,
           self_test_ok ? "pass" : "fail", action);

    xTaskCreate(heartbeat_task, "heartbeat", 3072, identity.serial, 5, NULL);
}
