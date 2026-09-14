#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "wasm_export.h"

enum { READY = 0, ERROR = 1 };
enum { STACK_SIZE = 64 * 1024, HEAP_SIZE = 16 * 1024, ERROR_SIZE = 256 };

typedef struct Definition {
    uint8_t *bytes;
    uint8_t *loaded_bytes;
    uint32_t byte_length;
    wasm_module_t module;
    wasm_module_inst_t instance;
    wasm_exec_env_t exec_env;
    wasm_function_inst_t function;
    char *name;
    uint32_t result_count;
    struct Definition *next;
} Definition;

static Definition *definitions;
static Definition *ephemeral;
static uint32_t *execution_results;
static uint32_t execution_result_count;
static bool execution_ready;
static char install_error[ERROR_SIZE];

static bool
read_submodule(package_type_t module_type, const char *module_name,
               uint8_t **buffer, uint32_t *size)
{
    Definition *definition;
    const char prefix[] = "wasm-forth:user/";
    (void)module_type;
    if (strncmp(module_name, prefix, sizeof(prefix) - 1) != 0)
        return false;
    for (definition = definitions; definition; definition = definition->next) {
        if (strcmp(module_name + sizeof(prefix) - 1, definition->name) == 0) {
            *buffer = malloc(definition->byte_length);
            if (!*buffer)
                return false;
            memcpy(*buffer, definition->bytes, definition->byte_length);
            *size = definition->byte_length;
            return true;
        }
    }
    return false;
}

static void
destroy_submodule(uint8_t *buffer, uint32_t size)
{
    (void)size;
    free(buffer);
}

static void
set_install_error(const char *message)
{
    snprintf(install_error, sizeof(install_error), "%s", message);
}

static bool
call_definition_from(wasm_exec_env_t exec_env, Definition *definition,
                     uint32_t argc, uint32_t *argv)
{
    wasm_module_inst_t caller = wasm_runtime_get_module_inst(exec_env);
    bool ok;
    wasm_runtime_set_module_inst(exec_env, definition->instance);
    ok = wasm_runtime_call_wasm(exec_env, definition->function, argc, argv);
    if (!ok) {
        const char *exception = wasm_runtime_get_exception(definition->instance);
        set_install_error(exception ? exception : "generated function trapped");
    }
    wasm_runtime_set_module_inst(exec_env, caller);
    return ok;
}

static void
destroy_definition(Definition *definition)
{
    if (!definition)
        return;
    if (definition->exec_env)
        wasm_runtime_destroy_exec_env(definition->exec_env);
    if (definition->instance)
        wasm_runtime_deinstantiate(definition->instance);
    if (definition->module)
        wasm_runtime_unload(definition->module);
    free(definition->bytes);
    free(definition->loaded_bytes);
    free(definition->name);
    free(definition);
}

static void
clear_extensions(void)
{
    while (definitions) {
        Definition *next = definitions->next;
        destroy_definition(definitions);
        definitions = next;
    }
    destroy_definition(ephemeral);
    ephemeral = NULL;
    free(execution_results);
    execution_results = NULL;
    execution_result_count = 0;
    execution_ready = false;
}

static Definition *
load_extension(uint8_t *bytes, uint32_t length)
{
    char error[ERROR_SIZE] = { 0 };
    uint8_t *owned = malloc(length);
    uint8_t *loaded = malloc(length);
    Definition *definition = calloc(1, sizeof(*definition));
    if (!owned || !loaded || !definition) {
        free(owned);
        free(loaded);
        free(definition);
        set_install_error("out of memory while loading extension");
        return NULL;
    }
    memcpy(owned, bytes, length);
    memcpy(loaded, bytes, length);
    definition->bytes = owned;
    definition->loaded_bytes = loaded;
    definition->byte_length = length;
    definition->module = wasm_runtime_load(loaded, length, error, sizeof(error));
    if (!definition->module) {
        set_install_error(error);
        destroy_definition(definition);
        return NULL;
    }
    return definition;
}

static bool
configure_export(Definition *definition)
{
    wasm_export_t export_type;
    int32_t export_count = wasm_runtime_get_export_count(definition->module);
    if (export_count != 1) {
        set_install_error("generated module must have exactly one export");
        return false;
    }
    wasm_runtime_get_export_type(definition->module, 0, &export_type);
    if (export_type.kind != WASM_IMPORT_EXPORT_KIND_FUNC) {
        set_install_error("generated module export is not a function");
        return false;
    }
    definition->name = strdup(export_type.name);
    definition->result_count =
        wasm_func_type_get_result_count(export_type.u.func_type);
    if (!definition->name) {
        set_install_error("could not copy generated function name");
        return false;
    }
    return true;
}

static bool
instantiate_extension(Definition *definition)
{
    char error[ERROR_SIZE] = { 0 };
    definition->instance = wasm_runtime_instantiate(
        definition->module, STACK_SIZE, HEAP_SIZE, error, sizeof(error));
    if (!definition->instance) {
        set_install_error(error);
        return false;
    }
    definition->exec_env =
        wasm_runtime_create_exec_env(definition->instance, STACK_SIZE);
    definition->function = wasm_runtime_lookup_function(definition->instance,
                                                        definition->name);
    if (!definition->exec_env || !definition->function) {
        set_install_error("could not resolve generated function export");
        return false;
    }
    return true;
}

static int32_t
host_install(wasm_exec_env_t exec_env, uint8_t *bytes, uint32_t length)
{
    Definition *definition;
    (void)exec_env;
    install_error[0] = '\0';
    definition = load_extension(bytes, length);
    if (!definition || !configure_export(definition)) {
        destroy_definition(definition);
        return 1;
    }
    if (!instantiate_extension(definition)) {
        destroy_definition(definition);
        return 1;
    }
    if (strcmp(definition->name, "__repl") == 0) {
        destroy_definition(ephemeral);
        ephemeral = definition;
        free(execution_results);
        execution_result_count = definition->result_count;
        execution_results = calloc(execution_result_count ? execution_result_count : 1,
                                   sizeof(uint32_t));
        if (!execution_results
            || !call_definition_from(exec_env, definition, 0,
                                     execution_results)) {
            if (!install_error[0])
                set_install_error("could not run __repl export");
            return 1;
        }
        execution_ready = true;
        return 0;
    }
    definition->next = definitions;
    definitions = definition;
    return 0;
}

static uint8_t *
read_file(const char *path, uint32_t *length)
{
    FILE *file = fopen(path, "rb");
    uint8_t *bytes;
    long size;
    if (!file || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0
        || fseek(file, 0, SEEK_SET) != 0) {
        if (file)
            fclose(file);
        return NULL;
    }
    bytes = malloc((size_t)size);
    if (!bytes || fread(bytes, 1, (size_t)size, file) != (size_t)size) {
        free(bytes);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *length = (uint32_t)size;
    return bytes;
}

static bool
call(wasm_exec_env_t env, wasm_function_inst_t function, uint32_t argc,
     uint32_t *argv, wasm_module_inst_t instance)
{
    if (wasm_runtime_call_wasm(env, function, argc, argv))
        return true;
    fprintf(stderr, "%s\n", wasm_runtime_get_exception(instance));
    return false;
}

int
main(int argc, char **argv)
{
    const char *compiler_path = argc > 1 ? argv[1] : "build/compiler.wasm";
    RuntimeInitArgs init_args = { 0 };
    NativeSymbol host_symbol = {
        "install", (void *)host_install, "(*~)i", NULL
    };
    uint8_t *compiler_bytes = NULL;
    uint32_t compiler_length = 0;
    wasm_module_t compiler_module = NULL;
    wasm_module_inst_t compiler_instance = NULL;
    wasm_exec_env_t compiler_env = NULL;
    wasm_function_inst_t reset, alloc, compile;
    char error[ERROR_SIZE] = { 0 };
    char *source = NULL;
    size_t source_capacity = 0;
    bool interactive = isatty(STDIN_FILENO);
    int exit_code = 1;

    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args)
        || !wasm_runtime_register_natives("wasm-forth:host", &host_symbol, 1)) {
        fprintf(stderr, "could not initialize WAMR\n");
        goto done;
    }
    wasm_runtime_set_module_reader(read_submodule, destroy_submodule);
    compiler_bytes = read_file(compiler_path, &compiler_length);
    if (!compiler_bytes) {
        fprintf(stderr, "could not read %s\n", compiler_path);
        goto done;
    }
    compiler_module = wasm_runtime_load(compiler_bytes, compiler_length, error,
                                        sizeof(error));
    if (!compiler_module) {
        fprintf(stderr, "%s\n", error);
        goto done;
    }
    compiler_instance = wasm_runtime_instantiate(
        compiler_module, STACK_SIZE, HEAP_SIZE, error, sizeof(error));
    if (!compiler_instance) {
        fprintf(stderr, "%s\n", error);
        goto done;
    }
    compiler_env = wasm_runtime_create_exec_env(compiler_instance, STACK_SIZE);
    reset = wasm_runtime_lookup_function(compiler_instance, "reset");
    alloc = wasm_runtime_lookup_function(compiler_instance, "alloc");
    compile = wasm_runtime_lookup_function(compiler_instance, "compile");
    if (!compiler_env || !reset || !alloc || !compile) {
        fprintf(stderr, "compiler ABI export is missing\n");
        goto done;
    }
    {
        uint32_t values[1] = { 0 };
        if (!call(compiler_env, reset, 0, values, compiler_instance))
            goto done;
    }
    if (interactive)
        fprintf(stderr, "WAMR wasm-forth REPL; each line is one source chunk\n");

    while (true) {
        ssize_t source_length;
        uint32_t values[3];
        uint32_t pointer;
        uint8_t *target;
        if (interactive) {
            fprintf(stderr, "wamr> ");
            fflush(stderr);
        }
        source_length = getline(&source, &source_capacity, stdin);
        if (source_length < 0)
            break;
        if (source_length == 1 && source[0] == '\n')
            continue;
        values[0] = (uint32_t)source_length;
        if (!call(compiler_env, alloc, 1, values, compiler_instance))
            goto done;
        pointer = values[0];
        target = wasm_runtime_addr_app_to_native(compiler_instance, pointer);
        if (!pointer || !target) {
            fprintf(stderr, "source allocation failed\n");
            goto done;
        }
        memcpy(target, source, (size_t)source_length);
        values[0] = pointer;
        values[1] = (uint32_t)source_length;
        values[2] = 0;
        execution_ready = false;
        if (!call(compiler_env, compile, 2, values, compiler_instance))
            goto done;
        if (install_error[0]) {
            fprintf(stderr, "%s\n", install_error);
            goto done;
        }
        if ((int32_t)values[0] == READY) {
            uint32_t i;
            if (execution_ready) {
                printf("RUN");
                for (i = 0; i < execution_result_count; i++)
                    printf(" %d", (int32_t)execution_results[i]);
                putchar('\n');
                destroy_definition(ephemeral);
                ephemeral = NULL;
                free(execution_results);
                execution_results = NULL;
                execution_result_count = 0;
                execution_ready = false;
            }
            else {
                puts("READY");
            }
        }
        else if ((int32_t)values[0] == ERROR) {
            uint8_t *message = wasm_runtime_addr_app_to_native(
                compiler_instance, values[1]);
            uint8_t *span = wasm_runtime_addr_app_to_native(compiler_instance,
                                                            256);
            uint32_t offset = 0, length = 0;
            if (span) {
                memcpy(&offset, span, sizeof(offset));
                memcpy(&length, span + 4, sizeof(length));
            }
            if (length) {
                fprintf(stderr, "%.*s", (int)source_length, source);
                fprintf(stderr, "%*s%.*s\n", (int)offset, "", (int)length,
                        "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^");
            }
            printf("ERROR %.*s\n", (int)values[2], (char *)message);
        }
        else {
            fprintf(stderr, "unexpected compiler status %d\n",
                    (int32_t)values[0]);
            goto done;
        }
    }
    exit_code = 0;

done:
    free(source);
    clear_extensions();
    if (compiler_env)
        wasm_runtime_destroy_exec_env(compiler_env);
    if (compiler_instance)
        wasm_runtime_deinstantiate(compiler_instance);
    if (compiler_module)
        wasm_runtime_unload(compiler_module);
    free(compiler_bytes);
    wasm_runtime_destroy();
    return exit_code;
}
