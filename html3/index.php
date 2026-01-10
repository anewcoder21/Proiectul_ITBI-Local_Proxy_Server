<!DOCTYPE html>
<html>

    <?php

        if(isset($_GET["user_input"]))
        {
            echo shell_exec("./server_files/script.sh " . $_GET["user_input"]);
        }

    ?>

    <form action="index.php" method="GET">
        <input type="text" name="user_input">
        <button type="submit">Trimite</button>
    </form>
</html>
