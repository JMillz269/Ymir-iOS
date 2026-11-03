# rcheevos - https://github.com/RetroAchievements/rcheevos
# - Only used by the iOS app (RetroAchievements support); built from its sources as a static library
set(RCHEEVOS_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/rcheevos)

add_library(rcheevos STATIC
    ${RCHEEVOS_ROOT}/src/rc_client.c
    ${RCHEEVOS_ROOT}/src/rc_compat.c
    ${RCHEEVOS_ROOT}/src/rc_util.c
    ${RCHEEVOS_ROOT}/src/rc_version.c
    ${RCHEEVOS_ROOT}/src/rapi/rc_api_common.c
    ${RCHEEVOS_ROOT}/src/rapi/rc_api_editor.c
    ${RCHEEVOS_ROOT}/src/rapi/rc_api_info.c
    ${RCHEEVOS_ROOT}/src/rapi/rc_api_runtime.c
    ${RCHEEVOS_ROOT}/src/rapi/rc_api_user.c
    ${RCHEEVOS_ROOT}/src/rcheevos/alloc.c
    ${RCHEEVOS_ROOT}/src/rcheevos/condition.c
    ${RCHEEVOS_ROOT}/src/rcheevos/condset.c
    ${RCHEEVOS_ROOT}/src/rcheevos/consoleinfo.c
    ${RCHEEVOS_ROOT}/src/rcheevos/format.c
    ${RCHEEVOS_ROOT}/src/rcheevos/lboard.c
    ${RCHEEVOS_ROOT}/src/rcheevos/memref.c
    ${RCHEEVOS_ROOT}/src/rcheevos/operand.c
    ${RCHEEVOS_ROOT}/src/rcheevos/rc_validate.c
    ${RCHEEVOS_ROOT}/src/rcheevos/richpresence.c
    ${RCHEEVOS_ROOT}/src/rcheevos/runtime.c
    ${RCHEEVOS_ROOT}/src/rcheevos/runtime_progress.c
    ${RCHEEVOS_ROOT}/src/rcheevos/trigger.c
    ${RCHEEVOS_ROOT}/src/rcheevos/value.c
    ${RCHEEVOS_ROOT}/src/rhash/aes.c
    ${RCHEEVOS_ROOT}/src/rhash/cdreader.c
    ${RCHEEVOS_ROOT}/src/rhash/hash.c
    ${RCHEEVOS_ROOT}/src/rhash/hash_disc.c
    ${RCHEEVOS_ROOT}/src/rhash/hash_encrypted.c
    ${RCHEEVOS_ROOT}/src/rhash/hash_rom.c
    ${RCHEEVOS_ROOT}/src/rhash/hash_zip.c
    ${RCHEEVOS_ROOT}/src/rhash/md5.c
)
target_include_directories(rcheevos
    PUBLIC ${RCHEEVOS_ROOT}/include
    PRIVATE ${RCHEEVOS_ROOT}/src ${RCHEEVOS_ROOT}/src/rcheevos ${RCHEEVOS_ROOT}/src/rhash ${RCHEEVOS_ROOT}/src/rapi
)
# The hash support of rc_client (game identification) is used with our own disc reader
target_compile_definitions(rcheevos PUBLIC RC_CLIENT_SUPPORTS_HASH=1)
set_target_properties(rcheevos PROPERTIES C_STANDARD 11 POSITION_INDEPENDENT_CODE ON)
