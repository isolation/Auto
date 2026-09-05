Auto 3
======

Description
-----------

Auto IRC Bot is an IRC channel bot that was created in
December of 2009; over time, it progressed into a bot with an
advanced and lightweight module API. Many of its features
are modules and can be loaded/unloaded to your wish.

Using the module API, you can also write your own modules to
further extend your copy.  If you think your module is useful
and should be included in the mainline program, you can
contact us and request that your module be added to
contributed modules. There is a chance that it will be accepted.

Please do see **Moving Forward** below, and NOTICE.md.

Module loading, unloading, and recovery are described in [doc/MODULES.md](doc/MODULES.md).

On-demand YouTube titles (`PLZ`) are described in [doc/YOUTUBE.md](doc/YOUTUBE.md).

Developers
----------

Auto 3 is developed by the Auto Project, a team
of people who contribute their time and knowledge to the
maintenance of Auto, and other projects.

- [mattwb65](https://github.com/mattwb65) &lt;mattwb65@gmail.com&gt;
- [noxgirl](https://github.com/noxgirl) &lt;xoeverlux@gmail.com&gt;

Inactive

- [RussellB28](https://github.com/RussellB28) &lt;russell@rbradford.me&gt;
- [liamsmithuk](https://github.com/liamsmithuk) &lt;me@liam.co&gt;
- [alyx](https://github.com/alyx) &lt;contact@alyxw.me&gt;
- [dwfreed](https://github.com/dwfreed)
- [grimreaper](https://github.com/grimreaper)
- [cooper](https://github.com/cooper)

Requirements
------------

Auto being a Perl IRC Bot obviously requires perl (5.10+) be installed. If you
use \*nix most package managers have this as 'perl'. If you're using OS X, this
is already installed on your system. Lastly, if you're using Windows we suggest
[Strawberry Perl](http://strawberryperl.com/).

Auto also requires a few CPAN modules in order to correctly function, they are:

+ IO::Async
+ Net::Async::HTTP
+ IO::Socket::IP
+ Class::Unload
+ IO::Async::Timer::Periodic
+ IO::Async::Stream
+ DBI

The following are required if built in a certain way:
+ IO::Socket::SSL (needed unless built with --disable-ssl)
+ MIME::Base64 (--enable-sasl)
+ DBD::mysql (--with-mysql)
+ DBD::Pg (--with-pgsql)
+ DBD::SQLite (needed unless built with --with-mysql or --with-pgsql)

Moving Forward
--------------

The Auto Project has initiated a significant revision of Auto, version four.
Please see the [official page here](http://git.io/autobot).

Moreover, note that Autumn (noxgirl, xoeverlux@gmail.com) has assumed
leadership of the project.

Help, Bugs, Suggestions
-----------------------

Unavailable at the moment.
