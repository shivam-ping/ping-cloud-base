import os
import unittest

from selenium.common.exceptions import NoSuchElementException
from selenium.webdriver.common.by import By
from selenium.webdriver.support.wait import WebDriverWait

import pingone_ui as p1_ui


@unittest.skipIf(
    os.environ.get("ENV_TYPE") == "customer-hub",
    "Customer-hub CDE detected, skipping test module",
)
class TestPAAdminUILogin(p1_ui.ConsoleUILoginTestBase):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.public_hostname = os.getenv(
            "PA_ADMIN_PUBLIC_HOSTNAME",
            f"https://pingaccess-admin.{os.environ['BELUGA_ENV_NAME']}.{os.environ['TENANT_DOMAIN']}",
        )

    def test_user_can_access_pa_admin_console(self):
        self.pingone_login()
        # Attempt to access the PingAccess Admin console with SSO
        self.browser.get(self.public_hostname)
        self.browser.implicitly_wait(10)
        try:
            title = self.browser.find_element(
                By.XPATH, "//div[contains(text(), 'Applications')]"
            )
            wait = WebDriverWait(self.browser, timeout=10)
            wait.until(lambda t: title.is_displayed())
            self.assertTrue(
                title.is_displayed(),
                "PingAccess Admin console 'Applications' page was not displayed. SSO may have failed.",
            )
        except NoSuchElementException:
            self.fail(
                "PingAccess Admin console 'Applications' page was not displayed. SSO may have failed."
            )


if __name__ == "__main__":
    unittest.main()
