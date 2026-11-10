<?php
$code = "v1";
echo "<h1>Code version: $code</h1>";
echo "<p>APP_VERSION setting: " . getenv('APP_VERSION') . "</p>";
echo "<p>DB_CONNECTION setting: " . getenv('DB_CONNECTION') . "</p>";
