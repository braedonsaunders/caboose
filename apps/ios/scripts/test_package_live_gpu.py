import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("package_live_gpu", Path(__file__).with_name("package-live-gpu.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ProviderExportsTests(unittest.TestCase):
    def commands(self, exported, extra_xml=""):
        with tempfile.TemporaryDirectory() as temp:
            registry = Path(temp) / "vk.xml"
            commands = "".join(f"<command><proto><name>{name}</name></proto></command>"
                               for name in package.REQUIRED_EXPORTS)
            registry.write_text(f"<registry><commands>{commands}{extra_xml}</commands></registry>")
            return package.provider_commands(exported, registry)

    def required_symbols(self):
        return "\n".join("_" + name for name in package.REQUIRED_EXPORTS)

    def test_missing_real_entrypoint_rejected(self):
        with self.assertRaises(ValueError):
            self.commands(self.required_symbols().replace("_vkCreateDevice", ""))

    def test_only_defined_declared_commands_retained(self):
        symbols = self.required_symbols() + "\n_vkPrivateFake\nU _vkNotDefined\n_vkAliasEXT\n_vkAliasEXT\n"
        names = self.commands(symbols, '<command name="vkAliasEXT" alias="vkCreateDevice"/>')
        self.assertEqual(set(names), package.REQUIRED_EXPORTS | {"vkAliasEXT"})
        self.assertEqual(names.count("vkAliasEXT"), 1)

    def test_registry_presence_does_not_invent_export(self):
        names = self.commands(self.required_symbols(), '<command name="vkAbsentEXT" alias="vkCreateDevice"/>')
        self.assertNotIn("vkAbsentEXT", names)

    def test_source_retains_real_addresses_not_dynamic_loader(self):
        source = package.provider_source(["vkCreateDevice", "vkGetInstanceProcAddr"])
        self.assertIn('reinterpret_cast<void*>(&vkCreateDevice)', source)
        self.assertIn('caboose_gpu_runtime_start(&vkGetInstanceProcAddr, resolve)', source)
        self.assertNotIn('dlsym', source)


if __name__ == "__main__":
    unittest.main()
