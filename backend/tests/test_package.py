import unittest

import can_monitor


class PackageTest(unittest.TestCase):
    def test_package_is_importable(self) -> None:
        self.assertEqual(can_monitor.__version__, "0.1.0")


if __name__ == "__main__":
    unittest.main()
