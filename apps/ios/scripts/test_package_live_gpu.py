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
        self.assertIn('caboose_gpu_runtime_start_v4(&vkGetInstanceProcAddr, resolve)', source)
        self.assertIn('int caboose_gpu_live_start_v4(void)', source)
        self.assertNotIn('caboose_gpu_runtime_start(', source)
        self.assertNotIn('dlsym', source)


    def test_indexed_link_probe_references_every_acquire_lifetime_operation(self):
        source = package.swift_link_probe()
        for name in ("caboose_gpu_surface_query_indexed", "caboose_gpu_virtual_swapchain_create",
                     "caboose_gpu_surface_query_variable_extent", "caboose_gpu_surface_configure_extent",
                     "caboose_gpu_virtual_swapchain_map", "caboose_gpu_acquire_begin", "caboose_gpu_acquire_poll",
                     "caboose_gpu_acquire_cancel", "caboose_gpu_acquire_observe", "caboose_gpu_acquire_request_release",
                     "caboose_gpu_virtual_swapchain_present", "caboose_gpu_virtual_swapchain_retire"):
            self.assertIn(name, package.REQUIRED_NATIVE)
            self.assertIn(name + "(", source)
        self.assertNotIn("caboose_gpu_live_start_v3", source)

    def test_memory_audit_requires_separate_module_and_real_symbols(self):
        plain = package.swift_link_probe()
        audit = package.swift_link_probe(memory_audit=True)
        self.assertNotIn("CabooseGPUMemoryAudit", plain)
        self.assertIn("import CabooseGPUMemoryAudit", audit)
        for symbol in package.AUDIT_NATIVE:
            self.assertIn(symbol + "(", audit)
        self.assertLess(audit.index("caboose_gpu_runtime_enable_memory_audit()"),
                        audit.index("caboose_gpu_live_start_v4()"))


if __name__ == "__main__":
    unittest.main()
