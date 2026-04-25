# Plan: Fix `secrets edit` to Support Multiline Values

## Context

`secrets add` uses `multiline()` for `encryption-key` type secrets to allow pasting multi-line PEM keys (Ctrl+D to submit). `secrets edit` always uses `password()` regardless of type, making it impossible to edit an encryption-key secret's value interactively. In `--yes` mode, the `--value <value>` CLI flag can't carry embedded newlines either. This fix brings `secrets edit` into parity with `secrets add`.

## Critical Files

- `apps/cli/src/cmd/secrets.ts` — only file that needs changing

## Changes

### 1. Add `--value-file` option to the `edit` command definition (line ~133)

```typescript
cmd.command('edit')
    .description('Edit an existing secret, field by field.')
    .option('--yes', 'Skip prompts')
    .option('--name <name>', 'Secret name to edit')
    .option('--new-name <name>', 'New secret name')
    .option('--value <value>', 'New value')
    .option('--value-file <path>', 'Read new value from a file (for multiline values such as PEM keys)')
    .action(secretsEdit);
```

### 2. Add `valueFile` to `ISecretsEditOptions` (line ~56)

```typescript
interface ISecretsEditOptions {
    yes?: boolean;
    name?: string;
    newName?: string;
    value?: string;
    // Path to a file whose content is used as the new secret value.
    valueFile?: string;
}
```

### 3. Handle `--value-file` in the `--yes` branch of `secretsEdit` (line ~433)

After the existing `--yes` guard, resolve `updatedValue` from `--value-file` when `--value` is absent:

```typescript
if (cmdOptions.yes) {
    if (!cmdOptions.newName && !cmdOptions.value && !cmdOptions.valueFile) {
        console.error(pc.red('✗ --new-name, --value, or --value-file is required with --yes'));
        await exit(1);
        return;
    }

    let updatedValue = secret.value;
    if (cmdOptions.valueFile) {
        if (!existsSync(cmdOptions.valueFile)) {
            console.error(pc.red(`✗ File not found: ${cmdOptions.valueFile}`));
            await exit(1);
            return;
        }
        updatedValue = await fs.readFile(cmdOptions.valueFile, 'utf-8');
    }
    else if (cmdOptions.value) {
        updatedValue = cmdOptions.value;
    }

    const updatedName = cmdOptions.newName || secret.name;

    if (updatedName !== secret.name) {
        await vault.delete(secret.name);
    }

    await vault.set({ name: updatedName, type: secret.type, value: updatedValue });
    console.log(pc.green(`✓ Secret "${updatedName}" updated.`));
    return;
}
```

### 4. Replace the always-`password()` prompt in the interactive branch (line ~470)

Mirror the conditional logic from `secretsAdd`:

```typescript
let newValue: string | symbol;

if (secret.type === 'encryption-key') {
    newValue = await multiline({
        message: 'New value (paste your key, then press Ctrl+D to submit; leave empty and Ctrl+D to keep current):',
    });
}
else {
    newValue = await password({
        message: `New value (leave blank to keep current):`,
    });
}

if (isCancel(newValue)) {
    outro(pc.yellow('Cancelled.'));
    return;
}
```

The rest of the function (using `newValue` to derive `updatedValue`) stays unchanged.

## Reused Utilities

- `multiline()` — already imported at line 4 of `secrets.ts`
- `existsSync` / `fs.readFile` — already imported at lines 6-7 of `secrets.ts`
- `isCancel()` — already imported at line 4

No new imports are needed.

## Verification

1. **Compile**: `bun run compile` from the repo root — must succeed with no TypeScript errors.
2. **Interactive multiline edit**: Run `psi secrets add --name test-key --type encryption-key --value ...` then `psi secrets edit --name test-key` and confirm the multiline prompt appears.
3. **`--value-file` non-interactive**: `psi secrets edit --name test-key --yes --value-file /path/to/key.pem` and confirm the value is updated.
4. **Smoke tests**: `./apps/cli/smoke-tests.sh` — existing `secrets edit` tests must still pass.
