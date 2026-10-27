idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES app_update esp_app_format esp_event esp_netif esp_partition esp_timer nvs_flash
                  protocol_examples_common
)
