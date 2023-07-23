# Changes for Simple_httpd

## Initial announce

I am pleased to announce the first alpha release of Simple_httpd, available on
github and opam. It is a library to produce web server and sites.

  Documentation: https://raffalli.eu/simple_httpd/simple_httpd
  Github       : https://github.com/craff/simple_httpd

WARNING: currently a version of markup with some PR submitted to
https://github.com/aantron/markup.ml and the master branch of ocaml-ssl are
needed.

It requires Linux and OCaml 5.0, if you are lucky to have this,
you can install with:

  opam pin add https://github.com/savonet/ocaml-ssl#master -k git
  opam pin add https://github.com/craff/markup#latest -k git
  opam pin add https://github.com/craff/simple_httpd -k git

It aims at

- Being simple to use and rather complete (support ssl, an equivalent of php,
  but in OCaml and compiled, and much more ...).

- Being fast: our latencies and number of requests per seconds are very good,
  thanks to using linux epoll, eventfd, OCaml's effects and domains, ...
  The first page of the documentation shows some graphics, but here is a small
  comparison of latencies for a small 1k file:

                 min        mean      50%       90%       95%      99%      max
  Simple_httpd  79.478µs 242.006µs 237.576µs 294.802µs 305.68µs 329.352µs  3.049ms
  Nginx        170.551µs 328.904µs 309.577µs 384.313µs 400.51µs 482.987µs 42.003ms
  Apaches      196.321µs 466.439µs 452.265µs 545.121µs 590.05µs 913.527µs  6.372ms

  And a small chaml (our equivalent of php) agains php-fpm:

  Simple_httpd 146.944µs 285.044µs 280.552µs 341.175µs 356.497µs 507.305µs  8.069ms
  Nginx        411.151µs 793.437µs 653.131µs 796.300µs 882.268µs     2.9ms 44.504ms
  Apache       688.765µs   2.342ms 950.647µs   1.201ms   1.321ms   5.844ms   1.171s

  These were obtained with vegeta at 1000 requests/s. Simple_httpd offers much
  more stable latencies under charge than nginx or apache.

- Currently only linux is supported.

Help, comments, bug reports, ... would be greatly appreciated.

My website https://raffalli.eu and therefore simple_httpd documentation are
powered by simple_httpd (do we name this bootstrap ;-) ?