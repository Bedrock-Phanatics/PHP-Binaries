<?php

declare(strict_types=1);

function nativeCheck(bool $condition, string $message): void{
	if(!$condition){
		throw new RuntimeException($message);
	}
}

nativeCheck(PHP_INT_SIZE === 8 && PHP_ZTS, '64-bit ZTS PHP is required');
foreach(['bedwire' => ['0.3.0', '0.4.0'], 'webrtc' => ['0.3.1', '0.4.0'], 'toml' => ['0.1.1', '0.2.0']] as $extension => [$min, $max]){
	$version = phpversion($extension);
	nativeCheck($version !== false && version_compare($version, $min, '>=') && version_compare($version, $max, '<'), "$extension version mismatch");
}
nativeCheck(class_exists(pmmp\webrtc\PeerConnection::class), 'Legacy WebRTC bindings are missing');
nativeCheck(function_exists('pmmp\webrtc\set_sctp_settings'), 'Legacy SCTP settings are missing');

$legacy = new pmmp\webrtc\PeerConnection(pmmp\webrtc\PeerConnectionOptions::create());
$disk = "\x0a\x00\x00\x03\x01\x00a" . pack('V', 5) . "\x00";
$network = Bedwire\Nbt::transcode($disk, Bedwire\Nbt::BEDROCK, Bedwire\Nbt::NETWORK);
nativeCheck(Bedwire\Nbt::transcode($network, Bedwire\Nbt::NETWORK, Bedwire\Nbt::BEDROCK) === $disk, 'NBT round trip failed');
try{
	Bedwire\Nbt::transcode(substr($disk, 0, -1), Bedwire\Nbt::BEDROCK, Bedwire\Nbt::NETWORK);
	throw new RuntimeException('Truncated NBT was accepted');
}catch(Bedwire\NbtException){
}
$packet = Bedwire\Protocol::encode('set_time', ['time' => -5]);
nativeCheck(Bedwire\Protocol::decode($packet) === ['time' => -5], 'Protocol round trip failed');
for($i = 0; $i < 5; ++$i){
	$server = new Bedwire\Server('127.0.0.1', 0, ['max_sessions' => 2, 'authentication' => false]);
	nativeCheck($server->isRunning() && $server->getPort() > 0, 'Native server failed to start');
	$port = $server->getPort();
	$server->stop(100);
	$server->stop(100);
	nativeCheck(!$server->isRunning() && $server->poll() === [], 'Native server failed to stop');
	unset($server);
	$server = new Bedwire\Server('127.0.0.1', $port, ['max_sessions' => 2, 'authentication' => false]);
	unset($server);
	nativeCheck($legacy->getBytesSent() === 0, 'Stopping Bedwire invalidated the legacy peer');
}
$legacy->close();
unset($legacy);
echo "Native extensions, NBT, protocol and server lifecycle OK\n";
