<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Download & Cache</title>
</head>
<body>

<?php

if (isset($_GET['user_input'])) {
    $url = trim($_GET['user_input']);

    // basic validation
    if (filter_var($url, FILTER_VALIDATE_URL) && preg_match('/^https?:\\/\\//', $url)) {
        // escape argument to avoid shell injection
        $escaped = escapeshellarg($url);
        // capture script output (stderr merged to stdout)
        $output = shell_exec("./server_files/script.sh " . $escaped . " 2>&1");
        $output = (string)$output;
        // show script output for debugging (optional)
        echo '<pre>' . htmlspecialchars($output, ENT_QUOTES | ENT_SUBSTITUTE) . '</pre>';

        // extract last non-empty line as the file path
        $lines = preg_split("/\r\n|\n|\r/", trim($output));
        $last = end($lines);

        // only accept files inside /var/www/html/cache
        if ($last && strpos($last, '/var/www/html/cache/') === 0 && is_file($last)) {
            $basename = basename($last);
            $cache_url = '/cache/' . rawurlencode($basename);

            // clickable link (fallback)
            echo '<p><a id="cached-link" href="' . htmlspecialchars($cache_url) . '" target="_blank" rel="noopener">Open cached file</a></p>';

            // JavaScript: navigate the window that was opened during submit
            echo '<script>
                (function(){
                    var url = "' . addslashes($cache_url) . '";
                    // The window was opened during the form submit with name "cachedFileWindow".
                    // Obtain a reference to that window (no popup will be created here).
                    var w = window.open("", "cachedFileWindow");
                    if (w && !w.closed) {
                        try {
                            w.location.href = url;
                        } catch (e) {
                            // as a fallback, navigate current window
                            window.location.href = url;
                        }
                    } else {
                        // if reference is missing (rare), navigate current window
                        window.location.href = url;
                    }
                })();
            </script>';
        } else {
            echo '<p>Could not find cached file path in script output.</p>';
        }
    } else {
        echo '<p>Invalid URL</p>';
    }
}
?>

<form id="fetchForm" action="index.php" method="GET" onsubmit="/* open blank window synchronously to avoid popup blocking */ window.open('about:blank', 'cachedFileWindow');">
    <input type="text" name="user_input" placeholder="https://example.com/page.html" size="60">
    <button type="submit">Trimite</button>
</form>

</body>
</html>
