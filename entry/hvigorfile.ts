import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import * as path from 'path';
import * as os from 'os';

// Patch ValidatorStore so cangjieOptions is accepted in build-profile.json5.
// The cangjie-aware schema lives in ~/.cangjie/build/<ver>/cj-plugin-cache/ and is
// generated when the project is built with DEVECO_CANGJIE_PATH set (e.g. via build.sh).
// This IIFE runs synchronously before hapTasks() validates the build profile.
(function patchCangjieSchema() {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const fs = require('fs') as typeof import('fs');
    const cjBuildBase = path.join(os.homedir(), '.cangjie', 'build');
    if (!fs.existsSync(cjBuildBase)) return;

    // Find the latest version dir that has a cj-plugin-cache with the module schema.
    const schemaName = 'ohos-module-build-profile-schema.json';
    let cjSchema = '';
    for (const ver of fs.readdirSync(cjBuildBase).sort().reverse()) {
      const candidate = path.join(cjBuildBase, ver, 'cj-plugin-cache', schemaName);
      if (fs.existsSync(candidate)) { cjSchema = candidate; break; }
    }
    if (!cjSchema) return;

    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { ValidatorStore } = require('@ohos/hvigor-ohos-plugin/src/utils/validate/validator-store');
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { BuildProfileSchemaFileConst } = require('@ohos/hvigor-ohos-plugin/src/const/common-const');
    const stdSchema: string = BuildProfileSchemaFileConst.HAP_MODULE_BUILD_PROFILE_SCHEMA_PATH;

    const validator = ValidatorStore.addValidator(cjSchema, false);
    ValidatorStore.getValidatorMap().set(`${stdSchema}:false`, validator);
  } catch (_) { /* schema patch is best-effort */ }
})();

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}
